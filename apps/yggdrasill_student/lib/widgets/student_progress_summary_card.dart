import 'package:flutter/material.dart';

/// 과제/교재 탭 상단 진행률 요약 카드.
class StudentProgressSummaryCard extends StatelessWidget {
  const StudentProgressSummaryCard({
    super.key,
    required this.percent,
    required this.subtitle,
    this.trailingSubtitle,
    this.trailingValue,
    this.onTap,
    this.showInfoIcon = true,
    this.infoFilled = false,
  });

  final int percent;
  final String subtitle;
  /// 두 번째 줄 오른쪽(예: 오늘 수행속도). null/빈 문자열이면 왼쪽만.
  final String? trailingSubtitle;
  /// 첫 줄 오른쪽(예: 총 계획시간). 있으면 i 아이콘 대신 표시.
  final String? trailingValue;
  final VoidCallback? onTap;
  final bool showInfoIcon;
  final bool infoFilled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final track = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE5E5EA);
    final fill = isDark
        ? Colors.white.withValues(alpha: 0.78)
        : const Color(0xFF3A3A3C);
    final clamped = percent.clamp(0, 100);
    final topTrailing = trailingValue?.trim() ?? '';

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$clamped',
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                          height: 1.0,
                          color: text,
                        ),
                      ),
                      TextSpan(
                        text: '%',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                          color: text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (topTrailing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    topTrailing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      letterSpacing: -0.4,
                      color: text,
                    ),
                  ),
                )
              else if (showInfoIcon)
                Icon(
                  infoFilled
                      ? Icons.info_rounded
                      : Icons.info_outline_rounded,
                  size: 22,
                  color: subText,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final lineStyle = theme.textTheme.bodyMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: subText,
                height: 1.25,
              );
              final trailing = trailingSubtitle?.trim() ?? '';
              if (trailing.isEmpty) {
                return Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: lineStyle,
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: lineStyle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    trailing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: lineStyle,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: clamped / 100,
              minHeight: 14,
              backgroundColor: track,
              valueColor: AlwaysStoppedAnimation<Color>(fill),
            ),
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? content
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(22),
                child: content,
              ),
      ),
    );
  }
}
