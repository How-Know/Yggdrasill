import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// Icons8 iOS Outlined "Done" (id 3061) 중심선.
/// viewBox 20에 20px로 그리면 선 굵기 1.6.
const String _dialogConfirmCheckSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M 2.8 11.54 L 8.74 16.76 L 17.2 3.86"/></svg>';

/// Icons8 iOS Outlined "Chevron Right" (id 40022) 중심선.
/// viewBox 20에 20px로 그리면 선 굵기 1.6.
const String dialogNextChevronSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M 6.2 3.6 L 14.2 10 L 6.2 16.4"/></svg>';

/// Icons8 iOS Outlined "Close" (id 46) 중심선.
/// viewBox 20에 20px로 그리면 선 굵기 1.6.
const String _dialogCloseXSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M 2.8 2.8 L 17.2 17.2 M 2.8 17.2 L 17.2 2.8"/></svg>';

/// 다이얼로그·시트 안에서 쓰는 작은 행동 버튼 크기.
///
/// 홈 우하단 [AppConfirmButton](140×56)보다 한 단계 작다.
/// 다른 화면의 확인·닫기는 이 크기를 기준으로 맞춘다.
abstract final class AppDialogActionMetrics {
  static const double width = 120;
  static const double height = 52;
}

/// 다이얼로그 안에서 쓰는 공용 확인 버튼.
///
/// 기본은 채움. 같은 줄의 보조 행동(완료, 다음)은 [filled]를 끈다.
class AppDialogConfirmButton extends StatelessWidget {
  static const double width = AppDialogActionMetrics.width;
  static const double height = AppDialogActionMetrics.height;

  const AppDialogConfirmButton({
    super.key,
    required this.onPressed,
    this.label = '확인',
    this.filled = true,
    this.iconOnly = false,
    this.showIcon = true,
    this.iconSvg = _dialogConfirmCheckSvg,
    this.iconLift = 1,
    this.iconDx = 0,
    this.groupEndPad = 10,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool filled;
  final bool iconOnly;

  /// 글자만 쓰는 행동(정답·오답·안함)은 체크 아이콘을 뺀다.
  final bool showIcon;
  final String iconSvg;

  /// 아이콘을 위로 올리는 양. 체크의 기본은 1.
  final double iconLift;

  /// 아이콘만 가로로 옮긴다. 음수면 왼쪽.
  final double iconDx;

  /// 묶음을 왼쪽으로 미는 오른쪽 여백. 10이면 아이콘 왼쪽이 5 줄어든다.
  final double groupEndPad;

  @override
  Widget build(BuildContext context) {
    return _AppDialogActionButton(
      label: label,
      onPressed: onPressed,
      filled: filled,
      iconSvg: iconSvg,
      iconOnly: iconOnly,
      showIcon: showIcon,
      iconLift: iconLift,
      iconDx: iconDx,
      groupEndPad: groupEndPad,
    );
  }
}

/// 다이얼로그 안에서 쓰는 공용 닫기 버튼.
///
/// 크기와 글자는 [AppDialogConfirmButton]과 같다.
class AppDialogCloseButton extends StatelessWidget {
  static const double width = AppDialogActionMetrics.width;
  static const double height = AppDialogActionMetrics.height;

  const AppDialogCloseButton({
    super.key,
    required this.onPressed,
    this.label = '닫기',
    this.iconOnly = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    return _AppDialogActionButton(
      label: label,
      onPressed: onPressed,
      filled: false,
      iconSvg: _dialogCloseXSvg,
      iconOnly: iconOnly,
    );
  }
}

class _AppDialogActionButton extends StatefulWidget {
  const _AppDialogActionButton({
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.iconSvg,
    this.iconOnly = false,
    this.showIcon = true,
    this.iconLift = 1,
    this.iconDx = 0,
    this.groupEndPad = 10,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final String iconSvg;
  final bool iconOnly;
  final bool showIcon;
  final double iconLift;
  final double iconDx;
  final double groupEndPad;

  @override
  State<_AppDialogActionButton> createState() => _AppDialogActionButtonState();
}

class _AppDialogActionButtonState extends State<_AppDialogActionButton> {
  bool _hovering = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final canTap = widget.onPressed != null;
    final brightness = Theme.of(context).brightness;
    final panel = PreviewAcademyPanelStyle.forBrightness(brightness);
    final border = FabTabBarTokens.groupedCardBorderFor(brightness).top.color;
    const accent = FabTabBarTokens.previewConfirmActionColor;
    final fill = widget.filled ? accent : Colors.transparent;
    final hoverFill = widget.filled
        ? Color.lerp(accent, Colors.white, 0.16)!
        : panel.title.withValues(alpha: 0.08);
    final color = _hovering && canTap ? hoverFill : fill;
    final foreground = widget.filled ? Colors.white : panel.title;

    return AnimatedScale(
      scale: _pressed && canTap ? 0.96 : 1,
      duration: Duration(milliseconds: _pressed ? 70 : 140),
      curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
      child: Opacity(
        opacity: canTap ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !canTap,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) {
              setState(() {
                _hovering = false;
                _pressed = false;
              });
            },
            cursor:
                canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
              onTapUp: canTap ? (_) => setState(() => _pressed = false) : null,
              onTapCancel:
                  canTap ? () => setState(() => _pressed = false) : null,
              onTap: widget.onPressed,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: widget.iconOnly
                      ? AppDialogActionMetrics.height
                      : AppDialogActionMetrics.width,
                  maxWidth: widget.iconOnly
                      ? AppDialogActionMetrics.height
                      : double.infinity,
                  minHeight: AppDialogActionMetrics.height,
                  maxHeight: AppDialogActionMetrics.height,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.center,
                  // 오른쪽 여백의 절반만큼 묶음이 왼쪽으로 간다. 아이콘 왼쪽 여백이 줄어든다.
                  padding: widget.iconOnly || !widget.showIcon
                      ? EdgeInsets.zero
                      : EdgeInsets.only(right: widget.groupEndPad),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(
                      AppDialogActionMetrics.height / 2,
                    ),
                    border: widget.filled
                        ? null
                        : Border.all(color: border, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.iconOnly || widget.showIcon)
                        Transform.translate(
                          offset: widget.iconOnly
                              ? Offset.zero
                              : Offset(widget.iconDx, -widget.iconLift),
                          child: SvgPicture.string(
                            widget.iconSvg,
                            width: 20,
                            height: 20,
                            colorFilter: ColorFilter.mode(
                              foreground,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      if (!widget.iconOnly) ...[
                        if (widget.showIcon) const SizedBox(width: 8),
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: foreground,
                            fontFamily: 'Pretendard',
                            fontSize: 18,
                            height: 1.0,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
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
