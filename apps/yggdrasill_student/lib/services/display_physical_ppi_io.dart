import 'dart:io';

import 'package:flutter/widgets.dart';

import 'windows_monitor_ppi.dart';

double? readDesktopPhysicalPpi() {
  if (!Platform.isWindows) return null;
  try {
    return windowsMonitorPhysicalPpi();
  } catch (_) {
    return null;
  }
}

var _fitScheduled = false;

/// 디버그 창이 105mm보다 좁으면 다음 프레임에 가로만 늘린다.
void scheduleQuestionPreviewWindowFit(double devicePixelRatio) {
  if (!Platform.isWindows || _fitScheduled) return;
  _fitScheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      ensureQuestionPreviewWindow(devicePixelRatio: devicePixelRatio);
    } catch (_) {}
  });
}
