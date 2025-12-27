import 'package:flutter/material.dart';

/// 좌측으로 스와이프(드래그)하여 우측 액션 패널을 노출하는 공용 래퍼.
///
/// - `onHorizontalDragUpdate/End` 기반으로 구현되어 데스크탑(마우스/트랙패드)에서도 동작한다.
/// - `child`의 탭 동작은 그대로 유지되며, 패널이 열린 상태에서 탭하면 먼저 닫힌다.
class SwipeActionReveal extends StatefulWidget {
  final Widget child;
  final Widget actionPane;
  final double actionPaneWidth;
  final BorderRadius borderRadius;
  final bool enabled;

  /// 스냅 애니메이션 시간
  final Duration snapDuration;

  /// 열림 임계값(0..1). 이 값 이상으로 열리면 손을 떼었을 때 열린 상태로 스냅.
  final double openThreshold;

  const SwipeActionReveal({
    super.key,
    required this.child,
    required this.actionPane,
    required this.actionPaneWidth,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.enabled = true,
    this.snapDuration = const Duration(milliseconds: 160),
    this.openThreshold = 0.38,
  });

  @override
  State<SwipeActionReveal> createState() => _SwipeActionRevealState();
}

class _SwipeActionRevealState extends State<SwipeActionReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.snapDuration);

  bool get _isOpen => _ctrl.value > 0.01;

  void _open() => _ctrl.animateTo(1, curve: Curves.easeOutCubic);
  void _close() => _ctrl.animateTo(0, curve: Curves.easeOutCubic);

  void _handleHorizontalDragUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    if (widget.actionPaneWidth <= 0) return;
    // 왼쪽으로 드래그(delta.dx < 0)하면 열림 진행도(value)가 증가한다.
    final next = _ctrl.value + (-d.delta.dx / widget.actionPaneWidth);
    _ctrl.value = next.clamp(0.0, 1.0);
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    if (!widget.enabled) return;
    final v = d.primaryVelocity ?? 0.0; // +: 오른쪽, -: 왼쪽
    if (v < -250) {
      _open();
      return;
    }
    if (v > 250) {
      _close();
      return;
    }
    if (_ctrl.value >= widget.openThreshold) {
      _open();
    } else {
      _close();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius;

    return GestureDetector(
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      onHorizontalDragCancel: _close,
      behavior: HitTestBehavior.translucent,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: widget.actionPaneWidth,
              child: widget.actionPane,
            ),
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) {
                final dx = -widget.actionPaneWidth * _ctrl.value;
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: GestureDetector(
                onTap: _isOpen ? _close : null,
                behavior: HitTestBehavior.translucent,
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


