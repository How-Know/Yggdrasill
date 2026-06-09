import 'package:flutter/material.dart';

import '../theme/ygg_semantic_colors.dart';

class DarkPanelRoute<T> extends PageRouteBuilder<T> {
  DarkPanelRoute({required Widget child})
      : super(
          opaque: false,
          barrierDismissible: false,
          barrierLabel: 'dark_panel',
          barrierColor: Colors.transparent,
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final fade = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
            final scale = Tween<double>(begin: 0.94, end: 1.0).animate(curved);

            return FadeTransition(
              opacity: fade,
              child: ScaleTransition(
                scale: scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: context.yggSurfaceBase),
                  child: child,
                ),
              ),
            );
          },
        );
}
