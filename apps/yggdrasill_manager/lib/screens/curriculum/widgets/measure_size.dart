import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

typedef OnWidgetSizeChange = void Function(Size size);

class MeasureSize extends StatefulWidget {
  final Widget child;
  final OnWidgetSizeChange onChange;

  const MeasureSize({
    super.key,
    required this.child,
    required this.onChange,
  });

  @override
  State<MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<MeasureSize> {
  final _widgetKey = GlobalKey();
  Size? _oldSize;

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifySize();
    });
    
    return Container(
      key: _widgetKey,
      child: widget.child,
    );
  }

  void _notifySize() {
    final context = _widgetKey.currentContext;
    if (context == null) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final size = renderBox.size;
    if (_oldSize != size) {
      _oldSize = size;
      widget.onChange(size);
    }
  }
}

