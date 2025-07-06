import 'package:flutter/material.dart';
import '../main.dart'; // rootNavigatorKey import

void showAppSnackBar(BuildContext context, String message, {bool useRoot = false}) {
  final scaffoldContext = useRoot ? rootNavigatorKey.currentContext! : context;
  ScaffoldMessenger.of(scaffoldContext).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: const Color(0xFF2A2A2A),
      duration: const Duration(seconds: 2),
    ),
  );
} 