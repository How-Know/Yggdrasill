import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../widgets/app_time_picker_dialog.dart';

/// FAB 스타일 탭바 색상·치수 토큰 (Preview 전용 — 본앱 미적용).
class FabTabBarTokens {
  const FabTabBarTokens._();

  /// Preview 학원 탭·FAB 탭 라벨 공통 기준 글자 크기
  static const double previewAcademyBaseFontSize = 16;

  static const double fabBarHeight = 56;

  /// [MainFabAlternative] + 버튼·[FabStyleScreenTabBarOverlay] 공통 하단 여백
  static const double fabBarBottomInset = 24;

  /// [MainFabAlternative] + 버튼·펼침 pill 공통 오른쪽 여백
  static const double fabBarRightInset = 24;

  /// 전역 메모 플로팅 배너 하단 — + 버튼·펼침 pill과 동일 기준선
  static double get fabMemoFloatingBottomInset =>
      fabBarBottomInset + fabBarHeight + fabMenuItemSpacing;

  /// 설정 화면 하단 [FabStyleTabBar] — 네비게이션 레일과의 좌측 여백
  static const double fabBarLeftInsetFromNavRail = 24;

  /// [NavigationRail] 기본 폭 — 오버레이 고정 배치용 ([navigation_rail.navRailMinWidth]와 동일)
  static const double fabBarNavRailDefaultWidth = 84.0;

  /// 하단 [FabStyleScreenTabBarOverlay]에 가려지지 않도록 본문 하단 여백
  static const double fabStyleScreenTabBarBottomPadding = 120.0;

  /// 글래스 블러 강도 (값↑ 뒤 화면 전체가 더 흐려져 비침)
  static const double fabBarBlurSigma = 28.0;

  /// FAB 스타일 탭바·+ 버튼 라벨 — Preview 학원 탭 [previewAcademyBaseFontSize]와 동일
  static const double fabBarLabelFontSize = previewAcademyBaseFontSize;

  /// Preview — 학원정보 패널 배경 Dark (스크린샷 기준)
  static const Color previewAcademyInfoPanelDark = Color(0xFF121212);

  /// Preview — 학원정보 패널 배경 Light
  /// [YggSemanticColors.surfaceBaseLight] (#F8F8F8) 대비 7단계 어두운 톤.
  static const Color previewAcademyInfoPanelLight = Color(0xFFF1F1F1);

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

  /// Preview — 2줄 행(아바타 + 제목/부제) 세로 패딩 (상·하 각각).
  /// 1줄 행보다 콘텐츠가 한 줄 더 높으므로 패딩은 줄여 전체 높이를 맞춘다.
  static const double previewAcademyGroupedTwoLineRowPaddingVertical = 16;

  /// Preview — 2줄 행 제목 ↔ 부제 사이 간격
  static const double previewAcademyTwoLineRowTitleToSubtitleSpacing = 3;

  /// Preview — 2줄 행 리딩(아바타) ↔ 텍스트 사이 간격
  static const double previewAcademyTwoLineRowLeadingGap = 14;

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
  static const double previewAcademyMenuTopOffsetFromArrow = 12;

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
      Duration(milliseconds: 40);

  /// Preview — 글래스 메뉴 틴트 (불투명도 90%)
  static const Color previewAcademyMenuGlassTintLight = Color(0xE6FFFFFF);
  static const Color previewAcademyMenuGlassTintDark = Color(0xE61C1C1E);

  /// Preview — 글래스 드롭다운 뒤 화면 흐림 (BackdropFilter)
  static const double previewAcademyMenuGlassBlurSigma = 18;
  // 화이트 모드: 흰 패널 위에서도 보이도록 반투명 검정(연한 회색) 사용.
  static const Color previewAcademyMenuGlassHoverOverlayLight =
      Color(0x14000000);
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

  /// 헤더 행 ↔ 입력 그룹 카드
  static const double previewAcademyInputSheetHeaderToFieldSpacing = 36;

  /// 입력 그룹 카드 안 — 카드 행 [previewAcademyGroupedRowPaddingHorizontal]과 동일
  static const double previewAcademyInputSheetFieldPaddingHorizontal = 24;

  /// 라벨 ↔ 입력란 가로 간격
  static const double previewAcademyInputSheetLabelToFieldSpacing = 52;

  /// 입력 시트 전용 — 다이얼로그 바깥 배경 (Dark)
  static const Color previewAcademyInputSheetSurfaceDark = Color(0xFF1C1C1E);

  /// 입력 시트 전용 — 입력 필드 그룹 배경 (Dark)
  static const Color previewAcademyInputSheetFieldSurfaceDark =
      Color(0xFF2C2C2E);

  /// Preview — 다이얼로그 위험 동작 문구 (삭제 등)
  static const Color previewAcademyDialogDestructiveTextColor =
      Color(0xFFFF554F);

  /// Preview — 공통 입력 시트 그룹 카드 배경.
  static Color previewAcademyDialogGroupedFillColor(Brightness brightness) {
    return brightness == Brightness.dark
        ? previewAcademyInputSheetFieldSurfaceDark
        : Colors.white;
  }

  /// 입력 시트 헤더 제목 글자 크기
  static const double previewAcademyInputSheetTitleFontSize = 20;

  /// 입력 행 한 줄 상·하 패딩 (각각)
  static const double previewAcademyInputSheetFieldRowPaddingVertical = 20;

  /// 입력 시트 열림·닫힘 슬라이드 애니메이션
  static const Duration previewAcademyInputSheetTransitionDuration =
      Duration(milliseconds: 280);

  /// 운영시간 알약 배지 — 좌우·상하 패딩
  static const double previewAcademyTimePillPaddingHorizontal = 20;
  static const double previewAcademyTimePillPaddingVertical = 9;
  static const double previewAcademyTimePillFontSize = 15;

  /// 운영시간 알약 배지 — 통통한 pill 유지
  static const double previewAcademyTimePillHeight = 44;

  /// 운영시간 전용 행 — 스위치 ON/OFF와 알약 유무에 관계없이 동일 높이
  static const double previewAcademyOperatingRowHeight = 80;

  /// 운영시간 알약 배지 — 시작·종료 사이 간격
  static const double previewAcademyTimePillGap = 6;

  /// 운영시간 알약 배지 — 배경은 [FabTabBarPalette.highlight] (FAB 탭 선택 하이라이트와 동일).
  /// 글자는 선택 탭 라벨([FabTabBarPalette.labelSelected])과 동일.

  /// 학원 탭 카드 라벨 왼쪽 = scope(16) + 카드 행(24). 시트 inner(16) + 필드(24)와 동일.
  static const double previewAcademyInputSheetFieldInsetFromSheet =
      previewAcademySectionScopePaddingHorizontal +
          previewAcademyGroupedRowPaddingHorizontal;

  /// Preview — 학원 로고 (지름 180)
  static const double previewAcademyLogoDiameter = 180;
  static const double previewAcademyLogoRadius = 90;

  /// Preview — 선생님 프로필 아바타 반지름 (로고 원보다 15% 작게).
  static const double previewTeacherAvatarRadius =
      previewAcademyLogoRadius * 0.85;

  /// Preview — 선생님 아바타 테두리 두께 (겹쳐 쌓일 때 배경색 테두리로 구분).
  static const double previewTeacherAvatarBorderWidth = 5;

  /// Preview — 겹쳐 쌓이는 아바타들의 가로 겹침 비율(지름 대비). 값↑ = 더 많이 겹침.
  static const double previewTeacherAvatarOverlapFraction = 0.42;

  /// Preview — 학원 로고 플레이스홀더 아이콘 크기
  static const double previewAcademyLogoIconSize = 69;

  /// Preview — 「변경」 버튼 세로 패딩
  static const double previewAcademyChangeButtonPaddingVertical = 14;

  /// Preview — 페이지·섹션 제목 Pretendard (Regular / SemiBold / Bold 등록)
  static const String previewHeadlineFontFamily = 'Pretendard';
  static const FontWeight previewHeadlineFontWeight = FontWeight.w700;

  /// Preview — 카드 행 **라벨** (학원명, 학원주소 …)
  static const String previewAcademyLabelFontFamily = 'Pretendard';
  static const double previewAcademyLabelFontSize = previewAcademyBaseFontSize;
  static const FontWeight previewAcademyLabelFontWeight = FontWeight.w400;

  /// Preview — 카드 행 **값·플레이스홀더** (앱 전역 기본 `KakaoSmallSans`)
  static const String previewAcademyValueFontFamily = 'KakaoSmallSans';
  static const double previewAcademyValueFontSize = previewAcademyBaseFontSize;
  static const FontWeight previewAcademyValueFontWeight = FontWeight.w400;

  static TextStyle previewPageTitleStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontWeight: previewHeadlineFontWeight,
      fontSize: previewAcademyBaseFontSize,
      color: style.title,
    );
  }

  /// Preview — 학원 탭 최상단 「학원정보」 전용 (32px).
  static TextStyle previewAcademyMainTitleStyle(
      PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewHeadlineFontFamily,
      fontWeight: previewHeadlineFontWeight,
      fontSize: previewAcademyMainTitleFontSize,
      height: 1.15,
      color: style.title,
    );
  }

  static TextStyle previewInternalTitleStyle(PreviewAcademyPanelStyle style) {
    return previewAcademyLabelStyle(style);
  }

  static TextStyle previewSectionTitleStyle(PreviewAcademyPanelStyle style) {
    return previewAcademyLabelStyle(style);
  }

  /// Preview — 카드·다이얼로그 행 라벨.
  static TextStyle previewAcademyLabelStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewAcademyLabelFontFamily,
      fontWeight: previewAcademyLabelFontWeight,
      fontSize: previewAcademyLabelFontSize,
      color: style.title,
    );
  }

  static TextStyle previewRowLabelStyle(PreviewAcademyPanelStyle style) {
    return previewAcademyLabelStyle(style);
  }

  /// Preview — 입력 시트 헤더 제목 (예: 「학원정보」).
  static TextStyle previewAcademyInputSheetTitleStyle(
    PreviewAcademyPanelStyle style,
  ) {
    return previewPageTitleStyle(style).copyWith(
      fontWeight: FontWeight.w600,
      fontSize: previewAcademyInputSheetTitleFontSize,
    );
  }

  /// Preview — 카드 행 값·미입력·힌트 공통 베이스.
  static TextStyle previewAcademyValueStyle(PreviewAcademyPanelStyle style) {
    return TextStyle(
      fontFamily: previewAcademyValueFontFamily,
      fontWeight: previewAcademyValueFontWeight,
      fontSize: previewAcademyValueFontSize,
      color: style.rowValue,
    );
  }

  static TextStyle previewRowValueStyle(PreviewAcademyPanelStyle style) {
    return previewAcademyValueStyle(style);
  }

  /// Preview — 2줄 행 **제목** (예: 선생님 이름). 라벨 폰트, 약간 큼·세미볼드.
  static TextStyle previewAcademyTwoLineTitleStyle(
    PreviewAcademyPanelStyle style,
  ) {
    return TextStyle(
      fontFamily: previewAcademyLabelFontFamily,
      fontWeight: FontWeight.w600,
      fontSize: 17,
      color: style.title,
    );
  }

  /// Preview — 2줄 행 **부제** (예: 역할/설명). 값 폰트, 작게·회색.
  static TextStyle previewAcademyTwoLineSubtitleStyle(
    PreviewAcademyPanelStyle style,
  ) {
    return previewAcademyValueStyle(style).copyWith(
      fontSize: 14,
      color: style.rowValue,
    );
  }

  /// Preview — 카드 행 값/플레이스홀더 (학원정보·정원·지불방식 통일)
  static TextStyle previewAcademyFieldDisplayStyle(
    PreviewAcademyPanelStyle style, {
    required bool isEmpty,
  }) {
    return previewAcademyValueStyle(style).copyWith(
      color: isEmpty ? style.hint : style.rowValue,
    );
  }

  /// Preview — 다이얼로그 입력란에 타이핑되는 본문.
  static TextStyle previewAcademyFieldInputStyle(
    PreviewAcademyPanelStyle style,
  ) {
    return previewAcademyValueStyle(style).copyWith(
      color: style.inputText,
    );
  }

  static TextStyle previewBodyTextStyle(
    PreviewAcademyPanelStyle style, {
    Color? color,
    FontWeight fontWeight = FontWeight.w400,
  }) {
    return TextStyle(
      fontFamily: previewAcademyValueFontFamily,
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
  static const Color fabBarLightHighlight = Color(0xB8CFCFCF);
  static const Color fabBarLightLabelSelected = Color(0xFF000000);
  static const Color fabBarLightLabelUnselected = Color(0xFF6B6B6B);

  /// FAB + 버튼·펼침 메뉴 pill 공통 라운드
  static const double fabMenuPillRadius = 16;

  /// + 버튼 ↔ 펼침 pill·pill 간 세로 간격 (등간격)
  static const double fabMenuItemSpacing = 12;

  /// 사이드시트 등원예정 학생 카드 — FAB 탭 하이라이트 알약
  static const double fabWaitingCardRadius = 25;
  static const EdgeInsets fabWaitingCardPadding =
      EdgeInsets.symmetric(horizontal: 22, vertical: 11);

  /// 라이트 모드 FAB·글래스 패널(등원 리스트 데코 포함) 공통 그림자
  /// (blur를 키우면 흰 글래스 주변에 회색 헤일로가 생겨 배경이 뿌연 것처럼 보임)
  static const List<BoxShadow> fabBarLightBoxShadows = [
    BoxShadow(
      color: Color(0x24000000),
      blurRadius: 4,
      offset: Offset(0, 2),
      spreadRadius: 0,
    ),
  ];

  /// 라이트 모드 글래스·알약 주변 블러·그림자 완화
  static double fabRelatedBlurSigmaFor(Brightness brightness) {
    return brightness == Brightness.light ? 10.0 : fabBarBlurSigma;
  }

  /// 하이라이트 알약 배경 — 라이트는 불투명 톤으로 뿌연 합성 방지
  static Color fabHighlightPillFill(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const Color(0xFFDCDCE0);
    }
    return paletteFor(brightness).highlight;
  }

  /// 공용 그룹 카드 행 누름 — FAB 탭 하이라이트를 카드 배경 위에 합성한 불투명 단일 색.
  static Color groupedCardRowPressFill(Brightness brightness) {
    final cardBg = brightness == Brightness.light
        ? previewAcademyInfoPanelLight
        : previewAcademyInfoPanelDark;
    return Color.alphaBlend(paletteFor(brightness).highlight, cardBg);
  }

  /// 플로팅 메모 배너 내부 패딩
  static const double fabMemoBannerPaddingLeft = 18;
  static const double fabMemoBannerPaddingRight = 14;
  static const double fabMemoBannerPaddingVertical = 16;

  /// 펼침 메뉴 아이콘 기준 크기 (메모)
  static const double fabMenuIconSize = 28;

  /// 펼침 메뉴 아이콘 — 메모 외 10% 축소
  static const double fabMenuIconSizeCompact = fabMenuIconSize * 0.9;

  /// FAB + 버튼·펼침 메뉴 — 다크 모드 최소 윤곽선
  static Border? fabRelatedBorderFor(Brightness brightness) {
    if (brightness == Brightness.light) return null;
    return Border.all(
      color: const Color(0x1AFFFFFF),
      width: 0.5,
      strokeAlign: BorderSide.strokeAlignInside,
    );
  }

  /// 학원·선생님 탭 공용 그룹 카드 — 라이트/다크 최소 윤곽선
  static Border groupedCardBorderFor(Brightness brightness) {
    if (brightness == Brightness.light) {
      return Border.all(
        color: const Color(0x12000000),
        width: 0.5,
        strokeAlign: BorderSide.strokeAlignInside,
      );
    }
    return Border.all(
      color: const Color(0x1AFFFFFF),
      width: 0.5,
      strokeAlign: BorderSide.strokeAlignInside,
    );
  }

  static TextStyle fabMenuLabelStyle(FabTabBarPalette palette) {
    return TextStyle(
      fontFamily: previewAcademyLabelFontFamily,
      color: palette.labelSelected,
      fontSize: fabBarLabelFontSize,
      fontWeight: FontWeight.w600,
    );
  }

  static FabTabBarPalette paletteFor(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const FabTabBarPalette(
        surface: fabBarLightSurface,
        highlight: fabBarLightHighlight,
        labelSelected: fabBarLightLabelSelected,
        labelUnselected: fabBarLightLabelUnselected,
        boxShadows: fabBarLightBoxShadows,
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

/// Preview — 운영시간 등 카드 행에 쓰는 알약형 시간 배지.
class PreviewAcademyTimePill extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String text;
  final bool isPlaceholder;
  final VoidCallback? onTap;

  const PreviewAcademyTimePill({
    super.key,
    required this.style,
    required this.text,
    this.isPlaceholder = false,
    this.onTap,
  });

  /// 12시간제 한국어 표기 (예: 오후 7:00).
  static String formatTimeOfDay(TimeOfDay time) {
    final period = time.hour < 12 ? '오전' : '오후';
    final h12 = time.hour % 12;
    final hour = h12 == 0 ? 12 : h12;
    final minute = time.minute.toString().padLeft(2, '0');
    return '$period $hour:$minute';
  }

  static const BorderRadius _pillRadius =
      BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = FabTabBarTokens.paletteFor(brightness);
    final rowPressed = GroupedCardPressScope.pressedOf(context);
    final background = rowPressed
        ? Colors.transparent
        : FabTabBarTokens.fabHighlightPillFill(brightness);
    final textColor = isPlaceholder ? style.hint : palette.labelSelected;

    final pillBody = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FabTabBarTokens.previewAcademyTimePillPaddingHorizontal,
        vertical: FabTabBarTokens.previewAcademyTimePillPaddingVertical,
      ),
      child: Center(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: FabTabBarTokens.previewAcademyValueFontFamily,
            fontSize: FabTabBarTokens.previewAcademyTimePillFontSize,
            fontWeight: FabTabBarTokens.previewAcademyValueFontWeight,
            color: textColor,
            height: 1.0,
          ),
        ),
      ),
    );

    final pill = SizedBox(
      height: FabTabBarTokens.previewAcademyTimePillHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: _pillRadius,
        ),
        child: pillBody,
      ),
    );

    if (onTap == null) return pill;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: pill,
      ),
    );
  }
}

/// Preview — 휴식 시간 구간.
@immutable
class PreviewAcademyBreakTimeRange {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;

  const PreviewAcademyBreakTimeRange({
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
  });

  String get displayLabel {
    final start = PreviewAcademyTimePill.formatTimeOfDay(
      TimeOfDay(hour: startHour, minute: startMinute),
    );
    final end = PreviewAcademyTimePill.formatTimeOfDay(
      TimeOfDay(hour: endHour, minute: endMinute),
    );
    return '$start - $end';
  }
}

/// Preview — 요일별 휴식 시간 목록 시트 (공용 다이얼로그 템플릿).
class PreviewAcademyBreakTimesSheet extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final List<PreviewAcademyBreakTimeRange> initialBreaks;

  const PreviewAcademyBreakTimesSheet({
    super.key,
    required this.style,
    required this.title,
    required this.initialBreaks,
  });

  static Future<List<PreviewAcademyBreakTimeRange>?> show({
    required BuildContext context,
    required PreviewAcademyPanelStyle style,
    required String title,
    required List<PreviewAcademyBreakTimeRange> initialBreaks,
  }) {
    return PreviewAcademyDialogRoute.show<List<PreviewAcademyBreakTimeRange>>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return PreviewAcademyBreakTimesSheet(
          style: style,
          title: title,
          initialBreaks: initialBreaks,
        );
      },
    );
  }

  @override
  State<PreviewAcademyBreakTimesSheet> createState() =>
      _PreviewAcademyBreakTimesSheetState();
}

class _PreviewAcademyBreakTimesSheetState
    extends State<PreviewAcademyBreakTimesSheet> {
  late List<PreviewAcademyBreakTimeRange> _breaks;

  @override
  void initState() {
    super.initState();
    _breaks = List.of(widget.initialBreaks);
  }

  void _close([List<PreviewAcademyBreakTimeRange>? value]) {
    Navigator.of(context).pop(value);
  }

  Future<void> _pickBreakRange({
    PreviewAcademyBreakTimeRange? initial,
    required void Function(PreviewAcademyBreakTimeRange value) onPicked,
  }) async {
    final startInitial = initial != null
        ? TimeOfDay(hour: initial.startHour, minute: initial.startMinute)
        : TimeOfDay.now();
    final start = await AppTimePickerDialog.show(
      context: context,
      title: widget.title,
      initialTime: startInitial,
    );
    if (start == null || !mounted) return;

    final endInitial = initial != null
        ? TimeOfDay(hour: initial.endHour, minute: initial.endMinute)
        : TimeOfDay(
            hour: (start.hour + 1) % 24,
            minute: start.minute,
          );
    final end = await AppTimePickerDialog.show(
      context: context,
      title: widget.title,
      initialTime: endInitial,
    );
    if (end == null || !mounted) return;

    onPicked(
      PreviewAcademyBreakTimeRange(
        startHour: start.hour,
        startMinute: start.minute,
        endHour: end.hour,
        endMinute: end.minute,
      ),
    );
  }

  Future<void> _addBreak() async {
    await _pickBreakRange(
      onPicked: (value) => setState(() => _breaks.add(value)),
    );
  }

  Future<void> _editBreak(int index) async {
    await _pickBreakRange(
      initial: _breaks[index],
      onPicked: (value) => setState(() => _breaks[index] = value),
    );
  }

  void _deleteBreak(int index) {
    setState(() => _breaks.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (int i = 0; i < _breaks.length; i++)
        _PreviewAcademyBreakTimeListRow(
          style: widget.style,
          label: '휴식 ${i + 1}',
          borderRadius: BorderRadius.vertical(
            top: i == 0
                ? const Radius.circular(
                    FabTabBarTokens.previewAcademyGroupedCardRadius,
                  )
                : Radius.zero,
          ),
          startText: PreviewAcademyTimePill.formatTimeOfDay(
            TimeOfDay(
              hour: _breaks[i].startHour,
              minute: _breaks[i].startMinute,
            ),
          ),
          endText: PreviewAcademyTimePill.formatTimeOfDay(
            TimeOfDay(
              hour: _breaks[i].endHour,
              minute: _breaks[i].endMinute,
            ),
          ),
          onTap: () => _editBreak(i),
          onDelete: () => _deleteBreak(i),
        ),
      if (_breaks.isNotEmpty)
        Divider(
          height: 1,
          thickness: 1,
          indent:
              FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
          endIndent:
              FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
          color: widget.style.divider,
        ),
      _PreviewAcademyBreakTimeAddRow(
        style: widget.style,
        borderRadius: BorderRadius.vertical(
          top: _breaks.isEmpty
              ? const Radius.circular(
                  FabTabBarTokens.previewAcademyGroupedCardRadius,
                )
              : Radius.zero,
          bottom: const Radius.circular(
            FabTabBarTokens.previewAcademyGroupedCardRadius,
          ),
        ),
        onTap: _addBreak,
      ),
    ];

    return PreviewAcademyDialogSheet(
      style: widget.style,
      title: widget.title,
      onCancel: () => _close(),
      onConfirm: () => _close(_breaks),
      child: PreviewAcademyDialogGroupedFields(
        style: widget.style,
        children: children,
      ),
    );
  }
}

class _PreviewAcademyBreakTimeListRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String label;
  final BorderRadius borderRadius;
  final String startText;
  final String endText;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PreviewAcademyBreakTimeListRow({
    required this.style,
    required this.label,
    required this.borderRadius,
    required this.startText,
    required this.endText,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(
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
                  style: FabTabBarTokens.previewRowLabelStyle(style),
                ),
              ),
              const SizedBox(
                width:
                    FabTabBarTokens.previewAcademyInputSheetLabelToFieldSpacing,
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PreviewAcademyTimePill(
                        style: style,
                        text: startText,
                      ),
                      const SizedBox(
                        width: FabTabBarTokens.previewAcademyTimePillGap,
                      ),
                      PreviewAcademyTimePill(
                        style: style,
                        text: endText,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Icon(Icons.close, size: 18, color: style.hint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewAcademyBreakTimeAddRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final BorderRadius borderRadius;
  final VoidCallback onTap;

  const _PreviewAcademyBreakTimeAddRow({
    required this.style,
    required this.borderRadius,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal:
                FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
            vertical:
                FabTabBarTokens.previewAcademyInputSheetFieldRowPaddingVertical,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.add,
                size: 18,
                color: FabTabBarTokens.previewConfirmActionColor,
              ),
              const SizedBox(width: 8),
              Text(
                '휴식 추가',
                style: FabTabBarTokens.previewBodyTextStyle(
                  style,
                  color: FabTabBarTokens.previewConfirmActionColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 공용 그룹 카드 행 누름 상태 — 자식(시간 알약 등)이 행 하이라이트와 겹치지 않게 한다.
class GroupedCardPressScope extends InheritedWidget {
  final bool pressed;

  const GroupedCardPressScope({
    super.key,
    required this.pressed,
    required super.child,
  });

  static bool pressedOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<GroupedCardPressScope>()
            ?.pressed ??
        false;
  }

  @override
  bool updateShouldNotify(GroupedCardPressScope oldWidget) {
    return oldWidget.pressed != pressed;
  }
}

/// 공용 그룹 카드 행 — 호버/ripple 없이 누르는 동안 FAB 탭 하이라이트로 전체 배경 표시.
class FabStyleGroupedCardTapTarget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const FabStyleGroupedCardTapTarget({
    super.key,
    required this.child,
    this.onTap,
  });

  @override
  State<FabStyleGroupedCardTapTarget> createState() =>
      _FabStyleGroupedCardTapTargetState();
}

class _FabStyleGroupedCardTapTargetState
    extends State<FabStyleGroupedCardTapTarget> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;

    final brightness = Theme.of(context).brightness;
    final pressFill = FabTabBarTokens.groupedCardRowPressFill(brightness);

    return GroupedCardPressScope(
      pressed: _pressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onTap,
          child: ColoredBox(
            color: _pressed ? pressFill : Colors.transparent,
            child: widget.child,
          ),
        ),
      ),
    );
  }
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

  static BoxDecoration cardDecoration(
    PreviewAcademyPanelStyle style, {
    required Brightness brightness,
  }) {
    return BoxDecoration(
      color: style.groupedCardBackground,
      borderRadius: BorderRadius.circular(
        FabTabBarTokens.previewAcademyGroupedCardRadius,
      ),
      border: FabTabBarTokens.groupedCardBorderFor(brightness),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: cardDecoration(
        style,
        brightness: Theme.of(context).brightness,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent:
                    FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                endIndent:
                    FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                color: style.divider,
              ),
            Builder(
              builder: (context) {
                final row = rows[i];
                final valueIsEmpty = row.value.isEmpty;
                final valueTextStyle =
                    FabTabBarTokens.previewAcademyFieldDisplayStyle(
                  style,
                  isEmpty: row.valueUsesHintStyle || valueIsEmpty,
                );
                final Widget valueArea;
                if (row.valueWidget != null && row.value.isEmpty) {
                  valueArea = row.valueWidget!;
                } else {
                  valueArea = Text(
                    valueIsEmpty ? (row.emptyPlaceholder ?? '미입력') : row.value,
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
                  return FabStyleGroupedCardTapTarget(
                    onTap: row.onTap,
                    child: child,
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
                    vertical:
                        FabTabBarTokens.previewAcademyGroupedRowPaddingVertical,
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

/// Preview — 「운영 시간」「앱」 등 섹션 라벨.
class PreviewAcademySectionHeader extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String title;

  const PreviewAcademySectionHeader({
    super.key,
    required this.style,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
      ),
      child: Text(
        title,
        style: FabTabBarTokens.previewSectionTitleStyle(style)
            .copyWith(color: style.hint),
      ),
    );
  }
}

/// Preview — 섹션 라벨 + 공용 그룹 카드.
class PreviewAcademyLabeledCardSection extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final Widget card;

  const PreviewAcademyLabeledCardSection({
    super.key,
    required this.style,
    required this.title,
    required this.card,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PreviewAcademySectionHeader(style: style, title: title),
        const SizedBox(
          height: FabTabBarTokens.previewAcademySectionHeaderToCardSpacing,
        ),
        card,
      ],
    );
  }
}

/// Preview — 임의의 행 위젯들을 iOS형 그룹 카드(라운드 + 행간 디바이더)로 감싼다.
///
/// 1줄 행([PreviewAcademyInfoRow] → [PreviewAcademyGroupedFieldsCard])과
/// 2줄 행([PreviewAcademyTwoLineRow])을 분리해 관리하기 위한 공용 셸.
class PreviewAcademyGroupedRowsCard extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final List<Widget> rows;

  const PreviewAcademyGroupedRowsCard({
    super.key,
    required this.style,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: PreviewAcademyGroupedFieldsCard.cardDecoration(
        style,
        brightness: Theme.of(context).brightness,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent:
                    FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                endIndent:
                    FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
                color: style.divider,
              ),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// 카드 하단 「+ … 추가」 행. 터치 영역은 아이콘·라벨 근처만 (행 전체 X).
class PreviewAcademyCardAddActionRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String label;
  final VoidCallback? onTap;
  final double rowHeight;

  const PreviewAcademyCardAddActionRow({
    super.key,
    required this.style,
    required this.label,
    this.onTap,
    this.rowHeight = FabTabBarTokens.previewAcademyOperatingRowHeight,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return SizedBox(
      height: rowHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal:
                FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
          ),
          child: MouseRegion(
            cursor:
                enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.deferToChild,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.add,
                      size: 18,
                      color: FabTabBarTokens.previewConfirmActionColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: FabTabBarTokens.previewBodyTextStyle(
                        style,
                        color: FabTabBarTokens.previewConfirmActionColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview — 그룹 카드 안에서 쓰는 2줄 행(리딩 아바타 + 제목/부제 + trailing/chevron).
class PreviewAcademyTwoLineRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final Widget? leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  const PreviewAcademyTwoLineRow({
    super.key,
    required this.style,
    this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.showChevron = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
        vertical:
            FabTabBarTokens.previewAcademyGroupedTwoLineRowPaddingVertical,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(
              width: FabTabBarTokens.previewAcademyTwoLineRowLeadingGap,
            ),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FabTabBarTokens.previewAcademyTwoLineTitleStyle(style),
                ),
                const SizedBox(
                  height: FabTabBarTokens
                      .previewAcademyTwoLineRowTitleToSubtitleSpacing,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      FabTabBarTokens.previewAcademyTwoLineSubtitleStyle(style),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ] else if (showChevron) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: FabTabBarTokens.previewAcademyChevronSize,
              color: style.chevron,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return FabStyleGroupedCardTapTarget(
      onTap: onTap,
      child: content,
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
  State<PreviewAcademyIosSwitch> createState() =>
      _PreviewAcademyIosSwitchState();
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

  // 초반 빠르게 펼쳐지고 마지막에 살짝 감속해 착지.
  static const _openCurve = Cubic(0.0, 0.88, 0.18, 1.0);
  static const _closeCurve = Cubic(0.55, 0.0, 1.0, 1.0);

  double _easedProgress(Animation<double> anim) {
    if (anim.status == AnimationStatus.reverse) {
      return _closeCurve.transform(anim.value);
    }
    return _openCurve.transform(anim.value);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      FabTabBarTokens.previewAcademyMenuRadius,
    );
    final shadows =
        FabTabBarTokens.paletteFor(Theme.of(context).brightness).boxShadows;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = _easedProgress(animation);

        // 위(앵커)에서 아래로 펼쳐지는 높이 reveal + 미세 스케일.
        //
        // Opacity 페이드는 쓰지 않는다 — Opacity는 saveLayer를 만들고
        // 완료 시(1.0) 이를 제거하는데, 그 순간 반투명 틴트가 제값으로
        // 드러나며 "흰 시트가 덧씌워진" 듯 밝아지는 팝이 생긴다.
        // 정적 글래스 카드(불투명 틴트)는 처음부터 같은 밝기로 펼쳐진다.
        final heightFactor = (0.1 + 0.9 * t).clamp(0.0, 1.0);
        final scale = 0.965 + 0.035 * t;
        // 라이트 모드 그림자는 blur가 클립 바깥으로 먼저 번져, 메뉴가
        // 아직 덜 펼쳐졌을 때 회색 호버 박스처럼 보일 수 있다. 패널 reveal이
        // 거의 끝난 뒤에만 짧게 fade-in 시켜 그림자와 콘텐츠 타이밍을 맞춘다.
        final shadowProgress = ((animation.value - 0.9) / 0.1).clamp(0.0, 1.0);
        final shadowOpacity = Curves.easeOut.transform(shadowProgress);
        final animatedShadows = [
          for (final shadow in shadows)
            shadow.copyWith(
              color: Color.lerp(
                Colors.transparent,
                shadow.color,
                shadowOpacity,
              )!,
            ),
        ];

        return Transform.scale(
          scale: scale,
          alignment: Alignment.topRight,
          filterQuality: FilterQuality.high,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: animatedShadows,
            ),
            child: ClipRRect(
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Align(
                alignment: Alignment.topRight,
                heightFactor: heightFactor,
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
  final Animation<double> animation;

  const _PreviewAcademyGlassMenuPanel({
    required this.style,
    required this.selectedId,
    required this.options,
    required this.onOptionSelected,
    required this.animation,
  });

  @override
  State<_PreviewAcademyGlassMenuPanel> createState() =>
      _PreviewAcademyGlassMenuPanelState();
}

class _PreviewAcademyGlassMenuPanelState
    extends State<_PreviewAcademyGlassMenuPanel> {
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
                color:
                    isDark ? const Color(0x33FFFFFF) : const Color(0x40FFFFFF),
                width: 0.5,
              ),
            ),
            // 라이브 BackdropFilter를 쓰지 않는다 — 드롭다운은 정적(모달)
            // 배경 위에 열리고 틴트가 이미 불투명에 가까워 블러 효과가
            // 거의 보이지 않는다. 대신 라이브 블러는 repaint마다 재합성되며
            // 틴트가 한 겹 더 겹친 듯 번쩍이는 아티팩트를 만든다. 정적
            // 틴트 카드로 바꿔 이 합성 아티팩트를 원천 제거한다.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              clipBehavior: Clip.antiAlias,
              child: ColoredBox(
                color: glassTint,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final option in widget.options)
                        _PreviewAcademyGlassMenuItem(
                          label: option.label,
                          selected: option.id == widget.selectedId,
                          hoverOverlay: hoverOverlay,
                          style: widget.style,
                          animation: widget.animation,
                          onTap: () => widget.onOptionSelected(option.id),
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

/// Preview — 글래스 메뉴 행 (호버 상태를 로컬로 관리해 패널 리빌드를 막음).
class _PreviewAcademyGlassMenuItem extends StatefulWidget {
  final String label;
  final bool selected;
  final Color hoverOverlay;
  final PreviewAcademyPanelStyle style;
  final Animation<double> animation;
  final VoidCallback onTap;

  const _PreviewAcademyGlassMenuItem({
    required this.label,
    required this.selected,
    required this.hoverOverlay,
    required this.style,
    required this.animation,
    required this.onTap,
  });

  @override
  State<_PreviewAcademyGlassMenuItem> createState() =>
      _PreviewAcademyGlassMenuItemState();
}

class _PreviewAcademyGlassMenuItemState
    extends State<_PreviewAcademyGlassMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: widget.animation,
          builder: (context, child) {
            // 펼침/접힘 중에는 마우스가 이미 행 위에 있어도 호버 색을 칠하지
            // 않는다. animation은 행 내부에서만 읽으므로 배리어/오버레이
            // 전체를 setState로 다시 빌드하지 않는다.
            final showHover = _hovered &&
                widget.animation.status == AnimationStatus.completed;
            return ColoredBox(
              color: showHover ? widget.hoverOverlay : Colors.transparent,
              child: child!,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: widget.selected
                      ? Icon(
                          Icons.check,
                          size: FabTabBarTokens.previewAcademyBaseFontSize,
                          color: widget.style.title,
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    widget.label,
                    style: FabTabBarTokens.previewMenuItemTextStyle(
                      widget.style,
                    ),
                  ),
                ),
              ],
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

/// Preview — 공통 입력 다이얼로그 경로/전환.
///
/// 학원정보 다이얼로그의 현재 모션(페이드 + 아래에서 슬라이드)을 기준으로 둔다.
class PreviewAcademyDialogRoute {
  PreviewAcademyDialogRoute._();

  static Future<T?> show<T>({
    required BuildContext context,
    required String barrierLabel,
    required WidgetBuilder builder,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: barrierLabel,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration:
          FabTabBarTokens.previewAcademyInputSheetTransitionDuration,
      pageBuilder: (context, animation, secondaryAnimation) {
        return builder(context);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
  }
}

/// Preview — 공통 입력 시트 shell.
///
/// 학원정보 다이얼로그의 배치·여백·색·버튼을 그대로 보존한다.
class PreviewAcademyDialogSheet extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final Widget child;

  const PreviewAcademyDialogSheet({
    super.key,
    required this.style,
    required this.title,
    required this.onCancel,
    required this.onConfirm,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetSurface = isDark
        ? FabTabBarTokens.previewAcademyInputSheetSurfaceDark
        : const Color(0xFFF2F2F7);
    final headerIconBg =
        isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);
    final subtleBorder =
        isDark ? const Color(0x33FFFFFF) : const Color(0x33000000);

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
              horizontal: FabTabBarTokens
                  .previewAcademyInputSheetOuterPaddingHorizontal,
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
                    FabTabBarTokens
                        .previewAcademyInputSheetInnerPaddingHorizontal,
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingTop,
                    FabTabBarTokens
                        .previewAcademyInputSheetInnerPaddingHorizontal,
                    FabTabBarTokens.previewAcademyInputSheetInnerPaddingBottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Center(
                              child: Text(
                                title,
                                textAlign: TextAlign.center,
                                style: FabTabBarTokens
                                    .previewAcademyInputSheetTitleStyle(style),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: _PreviewAcademyInputSheetIconButton(
                                backgroundColor: headerIconBg,
                                borderColor: subtleBorder,
                                icon: Icons.close,
                                iconColor: style.title,
                                onPressed: onCancel,
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: _PreviewAcademyInputSheetConfirmPill(
                                borderColor: subtleBorder,
                                onPressed: onConfirm,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: FabTabBarTokens
                            .previewAcademyInputSheetHeaderToFieldSpacing,
                      ),
                      child,
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

/// Preview — 공통 입력 시트 그룹 카드.
class PreviewAcademyDialogGroupedFields extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final List<Widget> children;

  const PreviewAcademyDialogGroupedFields({
    super.key,
    required this.style,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final groupedFill = FabTabBarTokens.previewAcademyDialogGroupedFillColor(
      Theme.of(context).brightness,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: groupedFill,
        borderRadius: BorderRadius.circular(
          FabTabBarTokens.previewAcademyGroupedCardRadius,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// Preview — 다이얼로그 하단 위험 동작 카드 (삭제 등).
class PreviewAcademyDialogDestructiveCard extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String label;
  final VoidCallback? onTap;

  const PreviewAcademyDialogDestructiveCard({
    super.key,
    required this.style,
    required this.label,
    this.onTap,
  });

  static const Color destructiveColor =
      FabTabBarTokens.previewAcademyDialogDestructiveTextColor;

  @override
  Widget build(BuildContext context) {
    final groupedFill = FabTabBarTokens.previewAcademyDialogGroupedFillColor(
      Theme.of(context).brightness,
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal:
            FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
        vertical:
            FabTabBarTokens.previewAcademyInputSheetFieldRowPaddingVertical,
      ),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: FabTabBarTokens.previewAcademyInputSheetTitleStyle(style)
              .copyWith(
            color: onTap == null ? style.hint : destructiveColor,
          ),
        ),
      ),
    );

    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: groupedFill,
          borderRadius: BorderRadius.circular(
            FabTabBarTokens.previewAcademyGroupedCardRadius,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: content,
                ),
              ),
      ),
    );
  }
}

/// Preview — 공통 입력 시트 필드 행.
class PreviewAcademyDialogFieldRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String emptyHintText;
  final int? maxLines;
  final int? minLines;

  const PreviewAcademyDialogFieldRow({
    super.key,
    required this.style,
    required this.label,
    required this.controller,
    this.focusNode,
    required this.textInputAction,
    this.onSubmitted,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.emptyHintText = '필수입력',
    this.maxLines = 1,
    this.minLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final hintStyle = FabTabBarTokens.previewAcademyFieldDisplayStyle(
      style,
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
              style: FabTabBarTokens.previewRowLabelStyle(style),
            ),
          ),
          const SizedBox(
            width: FabTabBarTokens.previewAcademyInputSheetLabelToFieldSpacing,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              maxLines: maxLines,
              minLines: minLines,
              style: FabTabBarTokens.previewAcademyFieldInputStyle(style),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: controller.text.trim().isEmpty ? emptyHintText : null,
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
}

/// Preview — 공통 입력 시트 드롭다운(피커) 행.
///
/// [PreviewAcademyInfoRow] 지불 방식 행과 동일하게 위·아래 화살표를 쓰고
/// 행 전체가 탭 대상이다.
class PreviewAcademyDialogPickerRow extends StatelessWidget {
  final PreviewAcademyPanelStyle style;
  final String label;
  final String value;
  final GlobalKey? anchorKey;
  final VoidCallback? onTap;
  final bool valueMuted;

  const PreviewAcademyDialogPickerRow({
    super.key,
    required this.style,
    required this.label,
    required this.value,
    this.anchorKey,
    this.onTap,
    this.valueMuted = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueStyle =
        FabTabBarTokens.previewAcademyFieldInputStyle(style).copyWith(
      color: valueMuted ? style.hint : null,
    );

    final row = Padding(
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
              style: FabTabBarTokens.previewRowLabelStyle(style),
            ),
          ),
          const SizedBox(
            width: FabTabBarTokens.previewAcademyInputSheetLabelToFieldSpacing,
          ),
          Expanded(
            child: Text(value, style: valueStyle),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            PreviewAcademyPaymentMenuAnchor(
              key: anchorKey,
              style: style,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return row;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: row,
      ),
    );
  }
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
    return PreviewAcademyDialogRoute.show<PreviewAcademyBasicInfoValues>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return PreviewAcademyFieldInputSheet(
          style: style,
          title: title,
          initialValues: initialValues,
          initialFocusField: initialFocusField,
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

  @override
  Widget build(BuildContext context) {
    final controllers = [
      _nameController,
      _addressController,
      _sloganController
    ];
    final focusNodes = [_nameFocusNode, _addressFocusNode, _sloganFocusNode];
    final submitActions = <VoidCallback?>[
      _addressFocusNode.requestFocus,
      _sloganFocusNode.requestFocus,
      _confirm,
    ];

    return PreviewAcademyDialogSheet(
      style: widget.style,
      title: widget.title,
      onCancel: () => _close(),
      onConfirm: _confirm,
      child: PreviewAcademyDialogGroupedFields(
        style: widget.style,
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
            PreviewAcademyDialogFieldRow(
              style: widget.style,
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
    );
  }
}

/// Preview — 정원·수업 입력 시트에서 포커스할 필드.
enum PreviewAcademyCapacityField {
  capacity,
  lessonDuration,
}

/// Preview — 기본 정원·수업 시간 입력 시트 결과.
class PreviewAcademyCapacityValues {
  final String capacity;
  final String lessonDurationMinutes;

  const PreviewAcademyCapacityValues({
    required this.capacity,
    required this.lessonDurationMinutes,
  });
}

/// Preview — 기본 정원·수업 시간 입력 시트.
class PreviewAcademyCapacityInputSheet extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final PreviewAcademyCapacityValues initialValues;
  final PreviewAcademyCapacityField initialFocusField;

  const PreviewAcademyCapacityInputSheet({
    super.key,
    required this.style,
    required this.title,
    required this.initialValues,
    this.initialFocusField = PreviewAcademyCapacityField.capacity,
  });

  static Future<PreviewAcademyCapacityValues?> show({
    required BuildContext context,
    required PreviewAcademyPanelStyle style,
    String title = '수업',
    required PreviewAcademyCapacityValues initialValues,
    PreviewAcademyCapacityField initialFocusField =
        PreviewAcademyCapacityField.capacity,
  }) {
    return PreviewAcademyDialogRoute.show<PreviewAcademyCapacityValues>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return PreviewAcademyCapacityInputSheet(
          style: style,
          title: title,
          initialValues: initialValues,
          initialFocusField: initialFocusField,
        );
      },
    );
  }

  @override
  State<PreviewAcademyCapacityInputSheet> createState() =>
      _PreviewAcademyCapacityInputSheetState();
}

class _PreviewAcademyCapacityInputSheetState
    extends State<PreviewAcademyCapacityInputSheet> {
  late final TextEditingController _capacityController;
  late final TextEditingController _lessonDurationController;
  late final FocusNode _capacityFocusNode;
  late final FocusNode _lessonDurationFocusNode;

  static const _fieldLabels = ['기본 정원', '수업 시간'];
  static const _emptyHints = ['명', '분'];
  static final _digitsOnly = FilteringTextInputFormatter.digitsOnly;

  @override
  void initState() {
    super.initState();
    _capacityController =
        TextEditingController(text: widget.initialValues.capacity);
    _lessonDurationController = TextEditingController(
      text: widget.initialValues.lessonDurationMinutes,
    );
    _capacityFocusNode = FocusNode();
    _lessonDurationFocusNode = FocusNode();
    for (final c in [_capacityController, _lessonDurationController]) {
      c.addListener(_onFieldChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focusNode = switch (widget.initialFocusField) {
        PreviewAcademyCapacityField.capacity => _capacityFocusNode,
        PreviewAcademyCapacityField.lessonDuration => _lessonDurationFocusNode,
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
    for (final c in [_capacityController, _lessonDurationController]) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    _capacityFocusNode.dispose();
    _lessonDurationFocusNode.dispose();
    super.dispose();
  }

  void _close([PreviewAcademyCapacityValues? values]) {
    Navigator.of(context).pop(values);
  }

  void _confirm() {
    _close(
      PreviewAcademyCapacityValues(
        capacity: _capacityController.text.trim(),
        lessonDurationMinutes: _lessonDurationController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controllers = [_capacityController, _lessonDurationController];
    final focusNodes = [_capacityFocusNode, _lessonDurationFocusNode];
    final submitActions = <VoidCallback?>[
      _lessonDurationFocusNode.requestFocus,
      _confirm,
    ];

    return PreviewAcademyDialogSheet(
      style: widget.style,
      title: widget.title,
      onCancel: () => _close(),
      onConfirm: _confirm,
      child: PreviewAcademyDialogGroupedFields(
        style: widget.style,
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
            PreviewAcademyDialogFieldRow(
              style: widget.style,
              label: _fieldLabels[i],
              controller: controllers[i],
              focusNode: focusNodes[i],
              keyboardType: TextInputType.number,
              inputFormatters: [_digitsOnly],
              emptyHintText: _emptyHints[i],
              textInputAction: i < _fieldLabels.length - 1
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: submitActions[i],
            ),
          ],
        ],
      ),
    );
  }
}

/// Preview — 공통 입력 시트 기반 단일 숫자 입력.
class PreviewAcademySingleNumberInputSheet extends StatefulWidget {
  final PreviewAcademyPanelStyle style;
  final String title;
  final String label;
  final String emptyHintText;
  final String initialValue;

  const PreviewAcademySingleNumberInputSheet({
    super.key,
    required this.style,
    required this.title,
    required this.label,
    required this.emptyHintText,
    required this.initialValue,
  });

  static Future<String?> show({
    required BuildContext context,
    required PreviewAcademyPanelStyle style,
    required String title,
    required String label,
    required String emptyHintText,
    required String initialValue,
  }) {
    return PreviewAcademyDialogRoute.show<String>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return PreviewAcademySingleNumberInputSheet(
          style: style,
          title: title,
          label: label,
          emptyHintText: emptyHintText,
          initialValue: initialValue,
        );
      },
    );
  }

  @override
  State<PreviewAcademySingleNumberInputSheet> createState() =>
      _PreviewAcademySingleNumberInputSheetState();
}

class _PreviewAcademySingleNumberInputSheetState
    extends State<PreviewAcademySingleNumberInputSheet> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  static final _digitsOnly = FilteringTextInputFormatter.digitsOnly;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    Navigator.of(context).pop(value);
  }

  void _confirm() {
    _close(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return PreviewAcademyDialogSheet(
      style: widget.style,
      title: widget.title,
      onCancel: () => _close(),
      onConfirm: _confirm,
      child: PreviewAcademyDialogGroupedFields(
        style: widget.style,
        children: [
          PreviewAcademyDialogFieldRow(
            style: widget.style,
            label: widget.label,
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            inputFormatters: [_digitsOnly],
            emptyHintText: widget.emptyHintText,
            textInputAction: TextInputAction.done,
            onSubmitted: _confirm,
          ),
        ],
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
                animation: _controller,
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
    // 오른쪽 위 화살표 기준으로 항상 같은 높이에서 펼쳐지게 한다.
    final anchorTopRight =
        anchor.localToGlobal(anchor.size.topRight(Offset.zero));
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 240.0;
    final top = anchorTopRight.dy -
        FabTabBarTokens.previewAcademyMenuTopOffsetFromArrow;
    final left = (anchorTopRight.dx - menuWidth)
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
    final textStyle = TextStyle(
      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
      fontWeight: FontWeight.w600,
      fontSize: fontSize,
    );
    final textDirection = Directionality.of(context);
    final slotWidths = tabs.map((label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: textDirection,
        maxLines: 1,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      return math.max(tabWidth, painter.width + 64);
    }).toList(growable: false);
    final safeSelectedIndex = slotWidths.isEmpty
        ? 0
        : selectedIndex.clamp(0, slotWidths.length - 1).toInt();
    final selectedLeft = slotWidths
        .take(safeSelectedIndex)
        .fold<double>(0.0, (sum, width) => sum + width);
    final selectedWidth =
        slotWidths.isEmpty ? tabWidth : slotWidths[safeSelectedIndex];
    final totalWidth =
        slotWidths.fold<double>(0.0, (sum, width) => sum + width);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: palette.boxShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(
              Theme.of(context).brightness,
            ),
            sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(
              Theme.of(context).brightness,
            ),
          ),
          child: Container(
            height: height,
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: SizedBox(
              width: totalWidth,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    left: selectedLeft,
                    top: 0,
                    bottom: 0,
                    width: selectedWidth,
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
                          width: slotWidths[index],
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: textStyle.copyWith(
                                color: isSelected
                                    ? palette.labelSelected
                                    : palette.labelUnselected,
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
              sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(
                Theme.of(context).brightness,
              ),
              sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(
                Theme.of(context).brightness,
              ),
            ),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.surface,
                border: FabTabBarTokens.fabRelatedBorderFor(
                  Theme.of(context).brightness,
                ),
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

/// FAB 계열 공통 글래스 패널 (메모 배너·펼침 pill 등).
class FabStyleGlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Border? border;

  /// 라이트 모드에서 FAB 글래스 대신 공용 그룹 카드 배경(#F1F1F1)을 쓴다.
  final bool useGroupedCardBackgroundInLight;

  const FabStyleGlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.border,
    this.useGroupedCardBackgroundInLight = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final brightness = Theme.of(context).brightness;
    final useGroupedCard =
        useGroupedCardBackgroundInLight && brightness == Brightness.light;
    final radius = BorderRadius.circular(
      useGroupedCard
          ? FabTabBarTokens.previewAcademyGroupedCardRadius
          : FabTabBarTokens.fabMenuPillRadius,
    );

    if (useGroupedCard) {
      final resolvedBorder =
          border ?? FabTabBarTokens.groupedCardBorderFor(brightness);
      return Container(
        decoration: BoxDecoration(
          color: FabTabBarTokens.previewAcademyInfoPanelLight,
          borderRadius: radius,
          border: resolvedBorder,
        ),
        padding: padding,
        child: child,
      );
    }

    final resolvedBorder =
        border ?? FabTabBarTokens.fabRelatedBorderFor(brightness);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: palette.boxShadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
            sigmaY: FabTabBarTokens.fabRelatedBlurSigmaFor(brightness),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: radius,
              border: resolvedBorder,
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// FAB 탭 **선택 하이라이트**와 동일한 알약 배경 (등원예정 카드 등).
class FabStyleHighlightPill extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Border? border;
  final double borderRadius;
  final Color? backgroundColor;

  const FabStyleHighlightPill({
    super.key,
    required this.child,
    this.padding = FabTabBarTokens.fabWaitingCardPadding,
    this.border,
    this.borderRadius = FabTabBarTokens.fabWaitingCardRadius,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final resolvedBorder =
        border ?? FabTabBarTokens.fabRelatedBorderFor(brightness);
    final radius = BorderRadius.circular(borderRadius);

    return ClipRRect(
      borderRadius: radius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor ??
              FabTabBarTokens.fabHighlightPillFill(brightness),
          borderRadius: radius,
          border: resolvedBorder,
        ),
        child: child,
      ),
    );
  }
}

/// 탭 시 카드 중심으로 빨려 들어가는 스케일·페이드 애니메이션 후 [onPressed] 실행.
class FabStyleSuckTap extends StatefulWidget {
  final Widget child;
  final Future<void> Function() onPressed;

  const FabStyleSuckTap({
    super.key,
    required this.child,
    required this.onPressed,
  });

  @override
  State<FabStyleSuckTap> createState() => _FabStyleSuckTapState();
}

class _FabStyleSuckTapState extends State<FabStyleSuckTap>
    with SingleTickerProviderStateMixin {
  static const double _pressScale = 0.96;

  late final AnimationController _suckController;
  bool _pressed = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _suckController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
  }

  @override
  void dispose() {
    _suckController.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_running) return;
    _running = true;
    if (mounted) setState(() => _pressed = false);
    try {
      await _suckController.forward();
      await widget.onPressed();
    } finally {
      if (mounted) {
        _suckController.reset();
        _running = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        if (_running) return;
        setState(() => _pressed = true);
      },
      onTapUp: (_) {
        if (!_running) setState(() => _pressed = false);
      },
      onTapCancel: () {
        if (!_running) setState(() => _pressed = false);
      },
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _suckController,
        builder: (context, child) {
          final suck = Curves.easeInCubic.transform(_suckController.value);
          final pressing = _pressed && suck == 0;
          final scale = (pressing ? _pressScale : 1.0) * (1.0 - suck * 0.94);
          final opacity = 1.0 - suck * 0.92;
          return Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale.clamp(0.0, 1.0),
              alignment: Alignment.center,
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// [FabStyleSuckTap]의 반대 — 중심에서 펼쳐지며 나타남 (등원학생 리스트 진입).
class FabStyleExpandIn extends StatefulWidget {
  final Widget child;
  final bool animate;
  final VoidCallback? onComplete;

  const FabStyleExpandIn({
    super.key,
    required this.child,
    this.animate = true,
    this.onComplete,
  });

  @override
  State<FabStyleExpandIn> createState() => _FabStyleExpandInState();
}

class _FabStyleExpandInState extends State<FabStyleExpandIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _expandController;

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    if (widget.animate) {
      _expandController.forward().then((_) {
        if (mounted) widget.onComplete?.call();
      });
    } else {
      _expandController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _expandController,
      builder: (context, child) {
        final expand = Curves.easeOutCubic.transform(_expandController.value);
        final scale = 0.06 + expand * 0.94;
        final opacity = 0.08 + expand * 0.92;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale.clamp(0.0, 1.0),
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// + 버튼 펼침 메뉴 pill — [FabStyleActionButton]·[FabStyleTabBar]와 동일 글래스 팔레트.
class FabStyleMenuPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// `true`면 [FabTabBarTokens.fabMenuIconSize], 아니면 10% 축소 아이콘.
  final bool useFullIconSize;

  const FabStyleMenuPill({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.useFullIconSize = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = FabTabBarTokens.paletteFor(Theme.of(context).brightness);
    final iconSize = useFullIconSize
        ? FabTabBarTokens.fabMenuIconSize
        : FabTabBarTokens.fabMenuIconSizeCompact;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: FabStyleGlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: palette.labelSelected,
              size: iconSize,
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: FabTabBarTokens.fabMenuLabelStyle(palette),
            ),
          ],
        ),
      ),
    );
  }
}

/// 설정·자료 등 화면 최상단 공용 페이지 타이틀 (학원정보·교재 등).
class FabStyleScreenMainTitle extends StatelessWidget {
  final String title;
  final double bottomSpacing;

  const FabStyleScreenMainTitle({
    super.key,
    required this.title,
    this.bottomSpacing = FabTabBarTokens.previewAcademyMainTitleToLogoSpacing,
  });

  @override
  Widget build(BuildContext context) {
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: FabTabBarTokens.previewAcademyTopInset),
        Text(
          title,
          textAlign: TextAlign.center,
          style: FabTabBarTokens.previewAcademyMainTitleStyle(style),
        ),
        SizedBox(height: bottomSpacing),
      ],
    );
  }
}

/// [MainFabAlternative] + 버튼 — 탭바 오버레이와 동일한 24px 여백 (Scaffold 기본 16px 대신).
class FabStyleFloatingActionButtonLocation
    extends FloatingActionButtonLocation {
  const FabStyleFloatingActionButtonLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final fabSize = scaffoldGeometry.floatingActionButtonSize;
    return Offset(
      scaffoldGeometry.scaffoldSize.width -
          fabSize.width -
          FabTabBarTokens.fabBarRightInset,
      scaffoldGeometry.scaffoldSize.height -
          fabSize.height -
          FabTabBarTokens.fabBarBottomInset,
    );
  }
}

/// 하단 FAB 스타일 탭바를 루트 오버레이에 고정 (슬라이드시트에 밀리지 않음).
class FabStyleScreenTabBarOverlay {
  OverlayEntry? _entry;
  int _selectedIndex = 0;
  List<String> _tabs = const [];
  ValueChanged<int>? _onTabSelected;
  bool _syncScheduled = false;
  bool _disposed = false;

  void sync(
    BuildContext context, {
    required int selectedIndex,
    required List<String> tabs,
    required ValueChanged<int> onTabSelected,
  }) {
    _disposed = false;
    _selectedIndex = selectedIndex;
    _tabs = tabs;
    _onTabSelected = onTabSelected;

    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (_disposed || !context.mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;

      if (_entry == null) {
        _entry = OverlayEntry(builder: _buildOverlay);
        overlay.insert(_entry!);
      } else {
        _entry!.markNeedsBuild();
      }
    });
  }

  void markNeedsBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _entry?.markNeedsBuild();
    });
  }

  void dispose() {
    _disposed = true;
    _entry?.remove();
    _entry = null;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final railWidth = NavigationRailTheme.of(overlayContext).minWidth ??
        FabTabBarTokens.fabBarNavRailDefaultWidth;
    return Positioned(
      left: railWidth + FabTabBarTokens.fabBarLeftInsetFromNavRail,
      bottom: FabTabBarTokens.fabBarBottomInset,
      child: FabStyleTabBar(
        selectedIndex: _selectedIndex,
        tabs: _tabs,
        onTabSelected: _onTabSelected ?? (_) {},
      ),
    );
  }
}
