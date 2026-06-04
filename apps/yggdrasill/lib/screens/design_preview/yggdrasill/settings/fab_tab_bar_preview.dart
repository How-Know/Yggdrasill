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

  /// Preview — 글래스 드롭다운 열림 애니메이션
  static const Duration previewAcademyMenuOpenDuration =
      Duration(milliseconds: 340);

  /// Preview — 섹션 타이틀 줄 ↔ 아래 카드 간격 (타이틀 줄만 좁게)
  static const double previewAcademySectionHeaderToCardSpacing = 8;

  static const double previewAcademyChevronSize = 20;

  /// Preview — 확인·저장·변경 등 주요 액션 문구 색 (본앱 `_kSignatureGreen`과 동일)
  static const Color previewConfirmActionColor = Color(0xFF33A373);

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
  static const Color fabBarDarkHighlight = Color(0x992A2A2A);
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
  final Widget? valueWidget;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  const PreviewAcademyInfoRow({
    required this.label,
    this.value = '',
    this.valueWidget,
    this.trailing,
    this.showChevron = true,
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
                final valueArea = row.valueWidget ??
                    Text(
                      row.value.isEmpty ? '미입력' : row.value,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: FabTabBarTokens.previewRowValueStyle(style),
                    );

                final rowBody = Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FabTabBarTokens
                        .previewAcademyGroupedRowPaddingHorizontal,
                    vertical: FabTabBarTokens
                        .previewAcademyGroupedRowPaddingVertical,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            row.label,
                            style: FabTabBarTokens.previewRowLabelStyle(style),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: row.onTap != null && row.trailing != null
                            ? Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: row.onTap,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: valueArea,
                                  ),
                                ),
                              )
                            : Align(
                                alignment: Alignment.centerRight,
                                child: valueArea,
                              ),
                      ),
                      if (row.trailing != null) ...[
                        const SizedBox(width: 8),
                        Center(child: row.trailing!),
                      ] else if (row.showChevron) ...[
                        const SizedBox(width: 4),
                        Center(
                          child: Icon(
                            Icons.chevron_right,
                            size: FabTabBarTokens.previewAcademyChevronSize,
                            color: style.chevron,
                          ),
                        ),
                      ],
                    ],
                  ),
                );

                if (row.onTap != null && row.trailing == null) {
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: row.onTap,
                      child: rowBody,
                    ),
                  );
                }

                return Material(
                  color: Colors.transparent,
                  child: rowBody,
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
class PreviewAcademyIosSwitch extends StatelessWidget {
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
  Widget build(BuildContext context) {
    const trackWidth = FabTabBarTokens.previewAcademySwitchWidth;
    const trackHeight = FabTabBarTokens.previewAcademySwitchHeight;
    const inset = FabTabBarTokens.previewAcademySwitchInset;
    final baseThumbWidth = (trackWidth - inset * 2) / 2 - 1;
    final thumbWidth =
        baseThumbWidth * FabTabBarTokens.previewAcademySwitchThumbWidthScale;
    final thumbHeight = trackHeight - inset * 2;
    final thumbRadius = thumbHeight / 2;

    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: trackWidth,
        height: trackHeight,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(trackHeight / 2),
                  color: value ? activeColor : inactiveColor,
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: value ? trackWidth - thumbWidth - inset : inset,
              top: inset,
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
  static const _closeCurve = Cubic(0.4, 0.0, 0.65, 1.0);

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

        return ClipRect(
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

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '닫기',
      barrierColor: Colors.transparent,
      transitionDuration: FabTabBarTokens.previewAcademyMenuOpenDuration,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final top = anchorBottomRight.dy + 6;
        final left = (anchorBottomRight.dx - menuWidth)
            .clamp(8.0, screenSize.width - menuWidth - 8);

        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: menuWidth,
              child: _PreviewAcademyGlassMenuTransition(
                animation: animation,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    FabTabBarTokens.previewAcademyMenuRadius,
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: FabTabBarTokens.fabBarBlurSigma,
                      sigmaY: FabTabBarTokens.fabBarBlurSigma,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xB31C1C1E)
                            : const Color(0xB3FFFFFF),
                        borderRadius: BorderRadius.circular(
                          FabTabBarTokens.previewAcademyMenuRadius,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 24,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (int i = 0; i < options.length; i++)
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => Navigator.of(dialogContext)
                                      .pop(options[i].id),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 28,
                                          child: options[i].id == selectedId
                                              ? Icon(
                                                  Icons.check,
                                                  size: FabTabBarTokens
                                                      .previewAcademyBaseFontSize,
                                                  color: style.title,
                                                )
                                              : null,
                                        ),
                                        Expanded(
                                          child: Text(
                                            options[i].label,
                                            style: FabTabBarTokens
                                                .previewBodyTextStyle(
                                              style,
                                              color: style.title,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
          ],
        );
      },
    );
  }
}

/// Preview — 지불 방식 iOS형 값 + 위·아래 화살표 + 체크 메뉴.
class PreviewAcademyPaymentTypeSelector extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String selectedId;
  final String valueLabel;
  final List<PreviewAcademyMenuOption> options;
  final ValueChanged<String> onSelected;

  const PreviewAcademyPaymentTypeSelector({
    super.key,
    required this.style,
    required this.selectedId,
    required this.valueLabel,
    required this.options,
    required this.onSelected,
  });

  @override
  State<PreviewAcademyPaymentTypeSelector> createState() =>
      _PreviewAcademyPaymentTypeSelectorState();
}

class _PreviewAcademyPaymentTypeSelectorState
    extends State<PreviewAcademyPaymentTypeSelector> {
  final GlobalKey _anchorKey = GlobalKey();

  Future<void> _openMenu() async {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: box,
      style: widget.style,
      selectedId: widget.selectedId,
      options: widget.options,
    );

    if (pickedId != null) {
      widget.onSelected(pickedId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openMenu,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.valueLabel,
              style: FabTabBarTokens.previewRowValueStyle(widget.style),
            ),
            const SizedBox(width: 4),
            Column(
              key: _anchorKey,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.keyboard_arrow_up,
                  size: 14,
                  color: widget.style.chevron,
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: widget.style.chevron,
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
