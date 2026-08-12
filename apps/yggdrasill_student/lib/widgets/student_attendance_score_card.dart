import 'package:flutter/material.dart';

/// 내 정보 상단 점수 요약 카드 (총점 / 출석 점수 등).
/// 과제 메뉴 [StudentProgressSummaryCard] 와 같은 탭→펼침 크로마.
class StudentAttendanceScoreCard extends StatelessWidget {
  const StudentAttendanceScoreCard({
    super.key,
    required this.title,
    required this.score100,
    required this.subtitle,
    this.onTap,
    this.showInfoIcon = true,
    this.infoFilled = false,
    this.showProgressBar = true,
    this.goalTitle,
    this.goalValue,
  });

  final String title;
  final double? score100;
  final String subtitle;
  final VoidCallback? onTap;
  final bool showInfoIcon;
  final bool infoFilled;
  final bool showProgressBar;

  /// 총점 카드 우측 "내 목표" 라벨. null이면 숨김.
  final String? goalTitle;

  /// 예: `상위 4%`. 기능 연동 전 플레이스홀더용.
  final String? goalValue;

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

    final numberStyle = theme.textTheme.displaySmall?.copyWith(
      fontSize: 44,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.2,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: title.trim().isEmpty
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ScoreValueWithUnit(
                            value: scoreLabel,
                            numberStyle: numberStyle,
                            unitStyle: unitStyle,
                          ),
                          if (goalTitle != null) ...[
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
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
                            numberStyle: numberStyle,
                            unitStyle: unitStyle,
                          ),
                        ],
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

/// 숫자·「점」을 같은 베이스라인에 두고, 「점」이 숫자보다 아래로 처지면 올려서
/// 글리프 하단을 맞춘다. (아래로 내리는 보정은 하지 않음)
class _ScoreValueWithUnit extends StatelessWidget {
  const _ScoreValueWithUnit({
    required this.value,
    required this.numberStyle,
    required this.unitStyle,
  });

  final String value;
  final TextStyle? numberStyle;
  final TextStyle? unitStyle;

  static const _heightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  static double _maxBottom(List<TextBox> boxes) {
    var bottom = boxes.first.bottom;
    for (final box in boxes) {
      if (box.bottom > bottom) bottom = box.bottom;
    }
    return bottom;
  }

  /// 「점」을 위로만 보정 (양수 = 상승 px).
  static double _liftUnitY({
    required String value,
    required TextStyle? numberStyle,
    required TextStyle? unitStyle,
    required TextScaler textScaler,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: value, style: numberStyle),
          TextSpan(text: '점', style: unitStyle),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      textHeightBehavior: _heightBehavior,
    )..layout();

    final numBoxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: value.length),
    );
    final unitBoxes = painter.getBoxesForSelection(
      TextSelection(
        baseOffset: value.length,
        extentOffset: value.length + 1,
      ),
    );
    if (numBoxes.isEmpty || unitBoxes.isEmpty) return 0;

    final overhang = _maxBottom(unitBoxes) - _maxBottom(numBoxes);
    // 점이 숫자보다 아래로 더 내려간 만큼만 올린다.
    return overhang > 0 ? overhang : 0;
  }

  @override
  Widget build(BuildContext context) {
    final lift = _liftUnitY(
      value: value,
      numberStyle: numberStyle,
      unitStyle: unitStyle,
      textScaler: MediaQuery.textScalerOf(context),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          textHeightBehavior: _heightBehavior,
          style: numberStyle,
        ),
        Transform.translate(
          offset: Offset(0, -lift),
          child: Text(
            '점',
            textHeightBehavior: _heightBehavior,
            style: unitStyle,
          ),
        ),
      ],
    );
  }
}
