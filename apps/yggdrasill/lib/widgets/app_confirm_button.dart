import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

/// Icons8 iOS Outlined "U Turn to Right" (id 106518).
const String _confirmUTurnSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 -4 58 58"><path fill="#000" stroke="#000" stroke-width="5.5" stroke-linejoin="round" stroke-linecap="round" d="M 38.990234 -0.009765625 A 1.0001 1.0001 0 0 0 38.292969 1.7070312 L 46.585938 10 L 17 10 A 1.0001 1.0001 0 0 0 16.886719 10.005859 C 7.5933822 10.068143 0 17.692783 0 27 C 0 36.309847 7.597607 43.936119 16.894531 43.994141 A 1.0001 1.0001 0 0 0 17 44 L 32 44 L 33 44 L 50 44 L 50 42 L 33 42 L 32 42 L 17 42 C 8.7454545 42 2 35.254545 2 27 C 2 18.745455 8.7454545 12 17 12 L 46.585938 12 L 38.292969 20.292969 A 1.0001 1.0001 0 1 0 39.707031 21.707031 L 49.707031 11.707031 A 1.0001 1.0001 0 0 0 49.707031 10.292969 L 39.707031 0.29296875 A 1.0001 1.0001 0 0 0 38.990234 -0.009765625 z"/></svg>';

/// 홈 완료 버튼과 같은 모양의 공용 확인 버튼.
///
/// 크기는 [width]×[height]. 다른 화면에서는 [label]만 바꿔 쓴다.
class AppConfirmButton extends StatelessWidget {
  static const double width = 140;
  static const double height = 56;

  final VoidCallback? onPressed;
  final String label;
  final bool enabled;
  final String? iconSvg;
  final double? buttonWidth;
  final Color? backgroundColor;

  const AppConfirmButton({
    super.key,
    required this.onPressed,
    this.label = '완료',
    this.enabled = true,
    this.iconSvg,
    this.buttonWidth,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return _AppConfirmButtonBody(
      onPressed: onPressed,
      label: label,
      enabled: enabled,
      iconSvg: iconSvg ?? _confirmUTurnSvg,
      buttonWidth: buttonWidth ?? width,
      backgroundColor:
          backgroundColor ?? FabTabBarTokens.previewConfirmActionColor,
    );
  }
}

class _AppConfirmButtonBody extends StatefulWidget {
  const _AppConfirmButtonBody({
    required this.onPressed,
    required this.label,
    required this.enabled,
    required this.iconSvg,
    required this.buttonWidth,
    required this.backgroundColor,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool enabled;
  final String iconSvg;
  final double buttonWidth;
  final Color backgroundColor;

  @override
  State<_AppConfirmButtonBody> createState() => _AppConfirmButtonBodyState();
}

class _AppConfirmButtonBodyState extends State<_AppConfirmButtonBody> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final canTap = widget.enabled && widget.onPressed != null;
    final color = _hovering && canTap
        ? Color.lerp(widget.backgroundColor, Colors.white, 0.16)!
        : widget.backgroundColor;
    return Opacity(
      opacity: canTap ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !canTap,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          cursor: canTap
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
          onTap: canTap ? widget.onPressed : null,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: widget.buttonWidth,
            height: AppConfirmButton.height,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: color,
                borderRadius:
                    BorderRadius.circular(AppConfirmButton.height / 2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.string(
                    widget.iconSvg,
                    width: 24,
                    height: 24,
                    colorFilter: const ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'Pretendard',
                      fontSize: 20,
                      height: 1.0,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w400,
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
