import 'package:flutter/material.dart';
import '../main.dart'; // rootNavigatorKey import

void showAppSnackBar(BuildContext context, String message, {bool useRoot = false}) {
  print('[DEBUG][showAppSnackBar] rootNavigatorKey.currentContext=${rootNavigatorKey.currentContext}');
  final scaffoldContext = useRoot ? rootNavigatorKey.currentContext : context;
  print('[DEBUG][showAppSnackBar] scaffoldContext=$scaffoldContext');
  ScaffoldMessenger.of(scaffoldContext!).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: const Color(0xFF2A2A2A),
      duration: const Duration(seconds: 2),
    ),
  );
} 