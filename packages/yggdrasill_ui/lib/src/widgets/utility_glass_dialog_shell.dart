import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/ygg_glass_tokens.dart';

/// 도구모음(파일 바로가기·PDF 편집·메모) 바텀시트와 동일한 글래스 다이얼로그 토큰.
///
/// 원본: apps/yggdrasill/lib/widgets/utility_glass_dialog_shell.dart (시범 공유 추출)
class UtilityGlassDialogTokens {
  static const Color glassTint = Color(0xB31C1C1E);
  static const Color borderColor = Color(0x33FFFFFF);
  static const Color iconColor = Color(0xFFF5F5F7);
  static const Color dividerColor = Color(0x22FFFFFF);
}

/// 중앙 모달용 글래스 다이얼로그 셸.
class UtilityGlassDialogShell extends StatelessWidget {
  const UtilityGlassDialogShell({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.maxWidth = 820,
    this.maxHeight = 760,
    this.preferredWidth,
    this.onClose,
    this.headerTrailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final double maxWidth;
  final double maxHeight;

  /// 지정 시 셸이 이 너비로 고정된다. (기본은 내용만큼만 줄어듦)
  final double? preferredWidth;
  final VoidCallback? onClose;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(28);
    const blurSigma = YggGlassTokens.menuGlassBlurSigma;

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: preferredWidth ?? 0,
        maxWidth: preferredWidth ?? maxWidth,
        maxHeight: maxHeight,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: const Color(0x40000000).withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: UtilityGlassDialogTokens.glassTint,
                  border: Border.all(
                    color: UtilityGlassDialogTokens.borderColor,
                    width: 0.5,
                  ),
                  borderRadius: radius,
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            color: UtilityGlassDialogTokens.iconColor,
                            size: 24,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: UtilityGlassDialogTokens.iconColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          if (headerTrailing != null) headerTrailing!,
                          IconButton(
                            tooltip: '닫기',
                            onPressed:
                                onClose ?? () => Navigator.of(context).pop(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Color(0xFFE3E3E6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(
                      height: 1,
                      color: UtilityGlassDialogTokens.dividerColor,
                    ),
                    Expanded(child: child),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showUtilityGlassDialog({
  required BuildContext context,
  required String title,
  required IconData icon,
  required Widget child,
  double? maxWidth,
  double? maxHeight,
  double? preferredWidth,
  Widget? headerTrailing,
}) {
  final media = MediaQuery.of(context);
  final resolvedMaxWidth = maxWidth ?? math.min(media.size.width - 48, 820.0);
  final resolvedMaxHeight = maxHeight ?? math.min(media.size.height - 48, 760.0);

  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: UtilityGlassDialogShell(
          title: title,
          icon: icon,
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight,
          preferredWidth: preferredWidth,
          headerTrailing: headerTrailing,
          child: child,
        ),
      );
    },
  );
}

/// 파일 바로가기·PDF 편집 도구모음과 동일하게 화면 하단에 붙는 글래스 시트.
Future<void> showUtilityGlassBottomSheet({
  required BuildContext context,
  required String title,
  required IconData icon,
  required Widget child,
  double? maxWidth,
  double? maxHeight,
  double? preferredWidth,
  Widget? headerTrailing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    constraints: preferredWidth == null
        ? null
        : BoxConstraints(maxWidth: maxWidth ?? double.infinity),
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      final resolvedMaxWidth =
          maxWidth ?? math.min(media.size.width - 48, 820.0);
      final resolvedMaxHeight =
          maxHeight ?? math.min(media.size.height * 0.72, 640.0);
      final resolvedPreferredWidth = preferredWidth == null
          ? null
          : math.min(preferredWidth, resolvedMaxWidth);

      return SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: resolvedPreferredWidth ?? 0,
                maxWidth: resolvedPreferredWidth ?? resolvedMaxWidth,
                maxHeight: resolvedMaxHeight,
              ),
              child: UtilityGlassDialogShell(
                title: title,
                icon: icon,
                maxWidth: resolvedMaxWidth,
                maxHeight: resolvedMaxHeight,
                preferredWidth: resolvedPreferredWidth,
                headerTrailing: headerTrailing,
                onClose: () => Navigator.of(sheetContext).pop(),
                child: child,
              ),
            ),
          ),
        ),
      );
    },
  );
}
