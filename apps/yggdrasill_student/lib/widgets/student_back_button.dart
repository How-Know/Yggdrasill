import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

/// 화면을 한 단계 뒤로 보내는 학생 앱 공용 버튼.
///
/// 학습 앱 교재 트리의 공용 뒤로가기와 같다. 크기·색·그림자는
/// [SolidCapsuleActionBarTokens]를 쓰고, 아이콘은 항상 뒤로 화살표다.
/// 새 뒤로가기를 만들지 말고 이 버튼을 쓴다.
class StudentBackButton extends StatelessWidget {
  const StudentBackButton({
    super.key,
    required this.onPressed,
    this.tooltip = '뒤로',
    this.size = 56,
    this.iconSize = 24,
  });

  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final fg = SolidCapsuleActionBarTokens.iconColor(brightness);

    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.arrow_back_rounded, size: iconSize, color: fg),
        ),
      ),
    );

    final child = tooltip == null || tooltip!.isEmpty
        ? button
        : Tooltip(message: tooltip, child: button);

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: SolidCapsuleActionBarTokens.boxShadows(brightness),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SolidCapsuleActionBarTokens.background(brightness),
          border: Border.all(
            color: SolidCapsuleActionBarTokens.border(brightness),
          ),
        ),
        child: child,
      ),
    );
  }
}
