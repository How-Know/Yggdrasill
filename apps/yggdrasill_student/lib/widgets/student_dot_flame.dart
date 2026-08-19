import 'package:flutter/material.dart';

Color? studentAttemptWarningColor(int attemptCount) => attemptCount >= 5
    ? const Color(0xFFFF3B30)
    : attemptCount >= 3
        ? const Color(0xFFFF9F0A)
        : null;
