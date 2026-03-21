import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

class LatexTextRenderer extends StatelessWidget {
  static final RegExp _displayRegex = RegExp(
    r'\$\$([\s\S]*?)\$\$',
    dotAll: true,
  );
  static final RegExp _inlineRegex = RegExp(
    r'\\\(([\s\S]*?)\\\)',
    dotAll: true,
  );
  static const double _inlineMathScale = 1.06;
  static const double _displayMathScale = 1.04;
  static const double _inlineMathBaselineShift = 1.0;

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final TextOverflow overflow;
  final int? maxLines;
  final bool softWrap;
  final bool enableDisplayMath;
  final double blockVerticalPadding;
  final CrossAxisAlignment crossAxisAlignment;

  const LatexTextRenderer(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.overflow = TextOverflow.clip,
    this.maxLines,
    this.softWrap = true,
    this.enableDisplayMath = true,
    this.blockVerticalPadding = 4,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  static bool hasLatex(String raw) {
    if (raw.isEmpty) return false;
    return _displayRegex.hasMatch(raw) || _inlineRegex.hasMatch(raw);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final displayMathTextStyle =
        _scaleMathTextStyle(effectiveStyle, _displayMathScale);
    if (!enableDisplayMath || !_displayRegex.hasMatch(text)) {
      return _buildInlineText(text, effectiveStyle);
    }

    final parts = _splitDisplayParts(text);
    final children = <Widget>[];
    for (final part in parts) {
      if (part.isDisplayMath) {
        final formula = part.content.trim();
        if (formula.isEmpty) {
          continue;
        }
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: blockVerticalPadding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Math.tex(
                formula,
                mathStyle: MathStyle.display,
                textStyle: displayMathTextStyle,
                onErrorFallback: (dynamic _) =>
                    Text(r'\$\$' + formula + r'\$\$', style: effectiveStyle),
              ),
            ),
          ),
        );
      } else if (part.content.isNotEmpty) {
        children.add(_buildInlineText(part.content, effectiveStyle));
      }
    }

    if (children.isEmpty) {
      return _buildInlineText(text, effectiveStyle);
    }
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildInlineText(String raw, TextStyle effectiveStyle) {
    final inlineMathTextStyle =
        _scaleMathTextStyle(effectiveStyle, _inlineMathScale);
    final spans = <InlineSpan>[];
    int lastIndex = 0;
    for (final match in _inlineRegex.allMatches(raw)) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(text: raw.substring(lastIndex, match.start)),
        );
      }

      final fullMatch = match.group(0) ?? '';
      final formula = (match.group(1) ?? '').trim();
      if (formula.isEmpty) {
        spans.add(TextSpan(text: fullMatch));
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: const Offset(0, _inlineMathBaselineShift),
              child: Math.tex(
                formula,
                textStyle: inlineMathTextStyle,
                mathStyle: MathStyle.text,
                onErrorFallback: (dynamic _) =>
                    Text(fullMatch, style: effectiveStyle),
              ),
            ),
          ),
        );
      }
      lastIndex = match.end;
    }

    if (lastIndex < raw.length) {
      spans.add(TextSpan(text: raw.substring(lastIndex)));
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: raw));
    }

    return RichText(
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      text: TextSpan(style: effectiveStyle, children: spans),
    );
  }

  List<_DisplayPart> _splitDisplayParts(String raw) {
    final matches = _displayRegex.allMatches(raw).toList();
    if (matches.isEmpty) {
      return <_DisplayPart>[const _DisplayPart.text('')];
    }

    int lastIndex = 0;
    final parts = <_DisplayPart>[];
    for (final match in matches) {
      if (match.start > lastIndex) {
        parts.add(_DisplayPart.text(raw.substring(lastIndex, match.start)));
      }
      parts.add(_DisplayPart.displayMath(match.group(1) ?? ''));
      lastIndex = match.end;
    }
    if (lastIndex < raw.length) {
      parts.add(_DisplayPart.text(raw.substring(lastIndex)));
    }
    return parts;
  }

  TextStyle _scaleMathTextStyle(TextStyle base, double scale) {
    final fontSize = base.fontSize;
    if (fontSize == null || fontSize <= 0) return base;
    return base.copyWith(fontSize: fontSize * scale);
  }
}

class _DisplayPart {
  final String content;
  final bool isDisplayMath;

  const _DisplayPart._({
    required this.content,
    required this.isDisplayMath,
  });

  const _DisplayPart.text(String content)
      : this._(content: content, isDisplayMath: false);

  const _DisplayPart.displayMath(String content)
      : this._(content: content, isDisplayMath: true);
}
