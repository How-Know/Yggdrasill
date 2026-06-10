import 'package:flutter/material.dart';
import '../main.dart'; // rootNavigatorKey import
import 'top_glass_snack_bar.dart';

/// 앱 공용 알림 — 화면 상단 가운데 iOS 스타일 글래스 스낵바로 표시한다.
void showAppSnackBar(BuildContext context, String message,
    {bool useRoot = false}) {
  final ctx = (useRoot ? rootNavigatorKey.currentContext : context) ?? context;
  TopGlassSnackBar.show(ctx, message: message);
}