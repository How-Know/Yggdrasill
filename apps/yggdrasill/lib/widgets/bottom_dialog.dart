import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'app_dialog_action_button.dart';
import 'dialog_tokens.dart';
import 'utility_glass_dialog_shell.dart';

/// 화면 하단에 붙는 글래스 다이얼로그.
///
/// 기준은 숙제 검사 대상 창. 새 하단 확인 창은 여기의 글자·여백·선택 목록을 쓴다.
abstract final class BottomDialogMetrics {
  static const double outerHorizontalPadding = 28;
  static const double outerBottomPadding = 18;
  static const double maxWidthCap = 560 * 1.1;
  static const double maxHeightCap = 640;
  static const double maxHeightFraction = 0.72;
  static const double radius = 28;

  static const double headerIconSize = 24;
  static const double headerIconGap = 10;
  static const double titleFontSize = 20;
  static const double headerPaddingLeft = 22;
  static const double headerPaddingTop = 14;
  static const double headerPaddingRight = 12;
  static const double headerPaddingBottom = 8;

  static const double bodyHorizontalPadding = 22;
  static const double bodyVerticalPadding = 24;

  static const double largeFontSize = 18;
  static const double mediumFontSize = 14;
  static const double smallFontSize = 13;
  static const double actionLabelFontSize = 16;
  static const double largeToMediumGap = 4;
  static const double beforeActionsGap = 18;

  static const double actionGap = 10;
  static const double actionIconSize = 22;
  static const double actionIconGap = 12;
  static const double actionLabelToDescriptionGap = 3;
  static const double actionContentVerticalPadding = 2;
  static const double cardRadius = 18;
  static const double cardHorizontalPadding = 14;
  static const double cardVerticalPadding = 12;

  static const double footerBottomPadding = 14;
  static const double barrierOpacity = 0.18;
}

/// 큰 글씨. 본문 맨 위 제목.
class BottomDialogLargeText extends StatelessWidget {
  const BottomDialogLargeText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Text(
      text,
      style: TextStyle(
        color: dlg.text,
        fontSize: BottomDialogMetrics.largeFontSize,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

/// 중간 글씨. 큰 글씨 바로 아래 보조 한 줄.
class BottomDialogMediumText extends StatelessWidget {
  const BottomDialogMediumText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Text(
      text,
      style: TextStyle(
        color: dlg.textSub,
        fontSize: BottomDialogMetrics.mediumFontSize,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 큰 글씨, 중간 글씨, 선택 목록을 정해진 간격으로 쌓는다.
class BottomDialogPrompt extends StatelessWidget {
  const BottomDialogPrompt({
    super.key,
    required this.large,
    this.medium,
    this.actions = const <Widget>[],
  });

  final String large;
  final String? medium;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final mediumText = medium?.trim() ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BottomDialogLargeText(large),
        if (mediumText.isNotEmpty) ...[
          const SizedBox(height: BottomDialogMetrics.largeToMediumGap),
          BottomDialogMediumText(mediumText),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: BottomDialogMetrics.beforeActionsGap),
          ...actions,
        ],
      ],
    );
  }
}

/// 선택 목록의 한 줄. 아이콘, 이름, 작은 설명, 오른쪽 화살표.
class BottomDialogActionTile extends StatelessWidget {
  const BottomDialogActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: BottomDialogMetrics.actionGap),
      child: BottomDialogCard(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: BottomDialogMetrics.actionContentVerticalPadding,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: kDlgAccent,
                size: BottomDialogMetrics.actionIconSize,
              ),
              const SizedBox(width: BottomDialogMetrics.actionIconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: dlg.text,
                        fontSize: BottomDialogMetrics.actionLabelFontSize,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(
                      height: BottomDialogMetrics.actionLabelToDescriptionGap,
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        color: dlg.textSub,
                        fontSize: BottomDialogMetrics.smallFontSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: dlg.textSub,
                size: BottomDialogMetrics.actionIconSize,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 목록·입력 묶음에 쓰는 둥근 카드. 누르면 카드 전체가 밝아진다.
class BottomDialogCard extends StatelessWidget {
  const BottomDialogCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    const radius = BorderRadius.all(
      Radius.circular(BottomDialogMetrics.cardRadius),
    );
    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BottomDialogMetrics.cardHorizontalPadding,
        vertical: BottomDialogMetrics.cardVerticalPadding,
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: radius,
        border: Border.all(color: dlg.cardBorder, width: 0.5),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? body
            : InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: body,
              ),
      ),
    );
  }
}

/// 글자 너비의 취소. 높이만 공용 확인 버튼과 같다.
class BottomDialogCancelButton extends StatelessWidget {
  const BottomDialogCancelButton({
    super.key,
    required this.onPressed,
    this.label = '취소',
  });

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final radius = BorderRadius.circular(AppDialogActionMetrics.height / 2);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Container(
          height: AppDialogActionMetrics.height,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dlg.chipBg,
            borderRadius: radius,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: dlg.chipText,
              fontFamily: 'Pretendard',
              fontSize: 18,
              height: 1.0,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 하단 글래스 다이얼로그 껍질.
class BottomDialog extends StatelessWidget {
  const BottomDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    required this.onClose,
    this.footer,
    this.actions = const <Widget>[],
    this.shrinkWrap = false,
    this.preferredWidth,
    this.maxHeight,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? footer;
  final List<Widget> actions;
  final VoidCallback onClose;
  final bool shrinkWrap;

  /// 지정하면 상한 616 대신 이 너비를 쓴다. 좌우 28을 뺀 화면보다 넓히지는 않는다.
  final double? preferredWidth;

  /// 지정하면 화면 72%·640 상한 대신 이 높이를 쓴다. 아래 18을 뺀 화면보다 키우지는 않는다.
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final glassTint = isDark
        ? UtilityGlassDialogTokens.glassTint
        : FabTabBarTokens.previewAcademyMenuGlassTintLight;
    final glassBorder = isDark
        ? UtilityGlassDialogTokens.borderColor
        : const Color(0x4D000000);
    final media = MediaQuery.of(context);
    final availableWidth = math.max(
      0.0,
      media.size.width - BottomDialogMetrics.outerHorizontalPadding * 2,
    );
    final requestedWidth = preferredWidth;
    final maxWidth = requestedWidth == null
        ? math.min(availableWidth, BottomDialogMetrics.maxWidthCap)
        : math.min(math.max(0.0, requestedWidth), availableWidth);
    final availableHeight = math.max(
      0.0,
      media.size.height - BottomDialogMetrics.outerBottomPadding,
    );
    final requestedHeight = maxHeight;
    final maxPanelHeight = requestedHeight == null
        ? math.min(
            media.size.height * BottomDialogMetrics.maxHeightFraction,
            BottomDialogMetrics.maxHeightCap,
          )
        : math.max(0.0, requestedHeight);
    final resolvedMaxHeight = math.min(maxPanelHeight, availableHeight);
    final radius = BorderRadius.circular(BottomDialogMetrics.radius);
    const blurSigma = FabTabBarTokens.previewAcademyMenuGlassBlurSigma;

    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            BottomDialogMetrics.outerHorizontalPadding,
            0,
            BottomDialogMetrics.outerHorizontalPadding,
            BottomDialogMetrics.outerBottomPadding,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: resolvedMaxHeight,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0x40000000).withValues(alpha: 0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                        ),
                        child: const ColoredBox(color: Colors.transparent),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: glassTint,
                        border: Border.all(color: glassBorder, width: 0.5),
                        borderRadius: radius,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          mainAxisSize: shrinkWrap
                              ? MainAxisSize.min
                              : MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                BottomDialogMetrics.headerPaddingLeft,
                                BottomDialogMetrics.headerPaddingTop,
                                BottomDialogMetrics.headerPaddingRight,
                                BottomDialogMetrics.headerPaddingBottom,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    icon,
                                    color: dlg.headerText,
                                    size: BottomDialogMetrics.headerIconSize,
                                  ),
                                  const SizedBox(
                                    width: BottomDialogMetrics.headerIconGap,
                                  ),
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: dlg.headerText,
                                        fontSize:
                                            BottomDialogMetrics.titleFontSize,
                                        fontWeight: FontWeight.w800,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '닫기',
                                    onPressed: onClose,
                                    icon: Icon(
                                      Icons.close_rounded,
                                      color: dlg.closeIcon,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(height: 1, color: dlg.divider),
                            if (shrinkWrap)
                              Flexible(
                                fit: FlexFit.loose,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    BottomDialogMetrics.bodyHorizontalPadding,
                                    BottomDialogMetrics.bodyVerticalPadding,
                                    BottomDialogMetrics.bodyHorizontalPadding,
                                    BottomDialogMetrics.bodyVerticalPadding,
                                  ),
                                  child: child,
                                ),
                              )
                            else
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    BottomDialogMetrics.bodyHorizontalPadding,
                                    BottomDialogMetrics.bodyVerticalPadding,
                                    BottomDialogMetrics.bodyHorizontalPadding,
                                    BottomDialogMetrics.bodyVerticalPadding,
                                  ),
                                  child: child,
                                ),
                              ),
                            if (footer != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  BottomDialogMetrics.bodyHorizontalPadding,
                                  0,
                                  BottomDialogMetrics.bodyHorizontalPadding,
                                  BottomDialogMetrics.footerBottomPadding,
                                ),
                                child: footer!,
                              )
                            else if (actions.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  10,
                                  18,
                                  BottomDialogMetrics.footerBottomPadding,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    for (var i = 0; i < actions.length; i++) ...[
                                      if (i > 0) const SizedBox(width: 8),
                                      actions[i],
                                    ],
                                  ],
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
      ),
    );
  }
}
