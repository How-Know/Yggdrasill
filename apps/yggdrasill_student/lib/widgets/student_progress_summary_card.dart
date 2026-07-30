import 'package:flutter/material.dart';

/// 과제/교재 탭 상단 진행률 요약 카드.
class StudentProgressSummaryCard extends StatelessWidget {
  const StudentProgressSummaryCard({
    super.key,
    required this.percent,
    required this.subtitle,
    this.onTap,
    this.showInfoIcon = true,
    this.infoFilled = false,
  });

  final int percent;
  final String subtitle;
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
              if (showInfoIcon)
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
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: subText,
              height: 1.25,
            ),
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
