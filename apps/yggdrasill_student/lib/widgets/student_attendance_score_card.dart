import 'package:flutter/material.dart';

/// 내 정보 상단 출석 점수 카드.
/// 목업 진행률 카드와 같은 크롬 · 진행 바, 상단은 타이틀/점수 정렬.
class StudentAttendanceScoreCard extends StatelessWidget {
  const StudentAttendanceScoreCard({
    super.key,
    required this.score100,
    required this.subtitle,
  });

  final double? score100;
  final String subtitle;

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

    final hasScore = score100 != null;
    final clamped = (score100 ?? 0).clamp(0.0, 100.0);
    final scoreLabel = hasScore ? clamped.toStringAsFixed(1) : '—';

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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '출석 점수',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: subText,
                    height: 1.0,
                  ),
                ),
                const Spacer(),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: scoreLabel,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                          height: 1.0,
                          color: text,
                        ),
                      ),
                      TextSpan(
                        text: '점',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                          color: text,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.right,
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
                value: hasScore ? clamped / 100 : 0,
                minHeight: 14,
                backgroundColor: track,
                valueColor: AlwaysStoppedAnimation<Color>(fill),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
