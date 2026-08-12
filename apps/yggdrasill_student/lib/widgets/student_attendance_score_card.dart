import 'package:flutter/material.dart';

/// 내 정보 상단 점수 요약 카드 (총점 / 출석 점수 등).
/// 과제 메뉴 [StudentProgressSummaryCard] 와 같은 탭→펼침 크로마.
class StudentAttendanceScoreCard extends StatelessWidget {
  const StudentAttendanceScoreCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.score100,
    this.valueLabel,
    this.onTap,
    this.showProgressBar = true,
    this.unit = '점',
    this.goalTitle,
    this.goalValue,
    this.onGoalTap,
  });

  final String title;

  /// 0~100 점수. [valueLabel]이 있으면 표시에는 쓰이지 않는다.
  final double? score100;

  /// 포인트처럼 클램프/소수 포맷이 필요 없을 때 직접 표기 (예: `1,240`).
  final String? valueLabel;

  final String subtitle;
  final VoidCallback? onTap;
  final bool showProgressBar;

  /// 점수 단위 표기. 누적 포인트는 `P`, 출석/과제는 `점`.
  final String unit;

  /// 총점 카드 우측 "내 목표" 라벨. null이면 숨김.
  final String? goalTitle;

  /// 예: `상위 4%`.
  final String? goalValue;

  /// 내 목표 영역 탭 (희망 등급 설정).
  final VoidCallback? onGoalTap;

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

    final hasScore = valueLabel != null || score100 != null;
    final clamped = (score100 ?? 0).clamp(0.0, 100.0);
    final scoreLabel = valueLabel ??
        (score100 != null ? clamped.toStringAsFixed(1) : '—');

    final numberStyle = theme.textTheme.displaySmall?.copyWith(
      fontSize: 44,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
      height: 1.0,
      color: text,
    );
    final unitStyle = theme.textTheme.titleLarge?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.0,
      color: text,
    );

    final content = Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 16, showProgressBar ? 18 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title.trim().isEmpty
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ScoreValueWithUnit(
                      value: scoreLabel,
                      unit: unit,
                      numberStyle: numberStyle,
                      unitStyle: unitStyle,
                    ),
                    if (goalTitle != null) ...[
                      const Spacer(),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onGoalTap,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 4, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  goalTitle!,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: subText,
                                    height: 1.15,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  goalValue ?? '상위 —%',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.4,
                                    height: 1.1,
                                    color: text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: subText,
                        height: 1.0,
                      ),
                    ),
                    const Spacer(),
                    _ScoreValueWithUnit(
                      value: scoreLabel,
                      unit: unit,
                      numberStyle: numberStyle,
                      unitStyle: unitStyle,
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
          if (showProgressBar) ...[
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

/// 큰 숫자와 단위(`pt` / `점`). 숫자와 간격을 두고, 단위를 숫자 하단보다
/// 살짝 위에 맞춰 광학적으로 균형 있게 보이게 한다.
class _ScoreValueWithUnit extends StatelessWidget {
  const _ScoreValueWithUnit({
    required this.value,
    required this.unit,
    required this.numberStyle,
    required this.unitStyle,
  });

  final String value;
  final String unit;
  final TextStyle? numberStyle;
  final TextStyle? unitStyle;

  static const _heightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          textHeightBehavior: _heightBehavior,
          style: numberStyle,
        ),
        Padding(
          // 숫자와 간격 + 하단을 숫자보다 조금 올려 단위가 처져 보이지 않게.
          padding: const EdgeInsets.only(left: 5, bottom: 5),
          child: Text(
            unit,
            textHeightBehavior: _heightBehavior,
            style: unitStyle,
          ),
        ),
      ],
    );
  }
}
