import 'package:flutter/material.dart';

abstract final class YggGroupedLayoutTokens {
  static const double maxContentWidth = 813;
  static const double horizontalInset = 16;
  static const double titleTopInset = 24;
  static const double titleBottomSpacing = 36;
  static const double sectionSpacing = 40;
  static const double sectionLabelSpacing = 8;
  static const double cardRadius = 28;
  static const double rowHorizontalPadding = 24;
  static const double rowVerticalPadding = 26;

  static Color cardBackground(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF121212)
          : const Color(0xFFF1F1F1);

  static Color cardBorder(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0x1AFFFFFF)
          : const Color(0x12000000);
}

class YggScreenMainTitle extends StatelessWidget {
  const YggScreenMainTitle({
    super.key,
    required this.title,
    this.trailing,
    this.topInset = YggGroupedLayoutTokens.titleTopInset,
    this.bottomSpacing = YggGroupedLayoutTokens.titleBottomSpacing,
  });

  final String title;
  final Widget? trailing;
  final double topInset;
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final titleColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Padding(
      padding: EdgeInsets.only(top: topInset, bottom: bottomSpacing),
      child: SizedBox(
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'KakaoBigSans',
                fontSize: 32,
                fontWeight: FontWeight.w700,
                height: 1.15,
                color: titleColor,
              ),
            ),
            if (trailing != null)
              Positioned(
                right: 0,
                child: trailing!,
              ),
          ],
        ),
      ),
    );
  }
}

class YggGroupedCard extends StatelessWidget {
  const YggGroupedCard({
    super.key,
    required this.child,
    this.padding,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      clipBehavior: clipBehavior,
      padding: padding,
      decoration: BoxDecoration(
        color: YggGroupedLayoutTokens.cardBackground(brightness),
        borderRadius: BorderRadius.circular(YggGroupedLayoutTokens.cardRadius),
        border: Border.all(
          color: YggGroupedLayoutTokens.cardBorder(brightness),
          width: 0.5,
        ),
      ),
      child: child,
    );
  }
}

class YggLabeledCardSection extends StatelessWidget {
  const YggLabeledCardSection({
    super.key,
    required this.label,
    required this.child,
    this.centerLabel = true,
  });

  final String label;
  final Widget child;
  final bool centerLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: centerLabel ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: Theme.of(context).hintColor,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: YggGroupedLayoutTokens.sectionLabelSpacing),
        child,
      ],
    );
  }
}
