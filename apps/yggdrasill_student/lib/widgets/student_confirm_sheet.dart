import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

/// 과제 추가·교재 리셋과 같은 하단 확인 시트.
Future<bool> showStudentConfirmSheet({
  required BuildContext context,
  required String title,
  String? message,
  String confirmLabel = '확인',
  String cancelLabel = '취소',
  IconData confirmIcon = Icons.check_rounded,
  IconData cancelIcon = Icons.close_rounded,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StudentConfirmSheet(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      confirmIcon: confirmIcon,
      cancelIcon: cancelIcon,
    ),
  );
  return result == true;
}

class StudentConfirmSheet extends StatelessWidget {
  const StudentConfirmSheet({
    super.key,
    required this.title,
    this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    this.confirmIcon = Icons.check_rounded,
    this.cancelIcon = Icons.close_rounded,
  });

  final String title;
  final String? message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData confirmIcon;
  final IconData cancelIcon;

  static const double _sheetRadius = 28;
  static const double _groupRadius = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final text = isDark ? Colors.white : Colors.black;
    final sub = text.withValues(alpha: 0.45);
    final divider = text.withValues(alpha: 0.08);
    final accent = YggGlassTokens.confirmActionColor;

    Widget option({
      required String label,
      required IconData icon,
      required Color iconColor,
      required BorderRadius inkRadius,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: inkRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Icon(icon, size: 26, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(_sheetRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: text,
                  ),
                ),
                if (message != null && message!.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: sub,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(_groupRadius),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_groupRadius),
                    child: Column(
                      children: [
                        option(
                          label: confirmLabel,
                          icon: confirmIcon,
                          iconColor: accent,
                          inkRadius: const BorderRadius.vertical(
                            top: Radius.circular(_groupRadius),
                          ),
                          onTap: () => Navigator.of(context).pop(true),
                        ),
                        Divider(
                          height: 1,
                          indent: 18,
                          endIndent: 18,
                          color: divider,
                        ),
                        option(
                          label: cancelLabel,
                          icon: cancelIcon,
                          iconColor: sub,
                          inkRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(_groupRadius),
                          ),
                          onTap: () => Navigator.of(context).pop(false),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
