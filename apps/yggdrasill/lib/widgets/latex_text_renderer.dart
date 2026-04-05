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
  static const double _defaultInlineMathScale = 1.06;
  static const double _defaultFractionInlineMathScale = 1.06;
  static const double _defaultDisplayMathScale = 1.04;
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
  final double inlineMathScale;
  final double fractionInlineMathScale;
  final double displayMathScale;

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
    this.inlineMathScale = _defaultInlineMathScale,
    this.fractionInlineMathScale = _defaultFractionInlineMathScale,
    this.displayMathScale = _defaultDisplayMathScale,
  });

  static bool hasLatex(String raw) {
    if (raw.isEmpty) return false;
    return _displayRegex.hasMatch(raw) || _inlineRegex.hasMatch(raw);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final displayMathTextStyle =
        _scaleMathTextStyle(effectiveStyle, displayMathScale);
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
                onErrorFallback: (dynamic _) => _buildMathFallback(
                  formula,
                  displayMathTextStyle,
                  mathStyle: MathStyle.display,
                ),
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
        final useDisplayLayout = _latexFormulaPrefersDisplay(formula);
        final fractionFormula =
            !useDisplayLayout && _isFractionFormula(formula);
        final nestedFraction = !useDisplayLayout &&
            fractionFormula &&
            RegExp(r'\\left|\\right').hasMatch(formula);
        final scaledStyle = _scaleMathTextStyle(
          effectiveStyle,
          useDisplayLayout
              ? displayMathScale
              : (fractionFormula ? fractionInlineMathScale : inlineMathScale),
        );
        final baselineShift = useDisplayLayout
            ? 0.0
            : (nestedFraction ? -0.4 : _inlineMathBaselineShift);
        final mathStyle =
            useDisplayLayout ? MathStyle.display : MathStyle.text;
        spans.add(
          WidgetSpan(
            alignment: useDisplayLayout
                ? PlaceholderAlignment.middle
                : PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: Offset(0, baselineShift),
              child: Math.tex(
                formula,
                textStyle: scaledStyle,
                mathStyle: mathStyle,
                onErrorFallback: (dynamic _) => _buildMathFallback(
                  formula,
                  scaledStyle,
                  mathStyle: mathStyle,
                ),
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

  Widget _buildMathFallback(
    String formula,
    TextStyle mathTextStyle, {
    required MathStyle mathStyle,
  }) {
    final normalized = _normalizeFormulaForRetry(formula);
    if (normalized.isNotEmpty && normalized != formula) {
      return Math.tex(
        normalized,
        textStyle: mathTextStyle,
        mathStyle: mathStyle,
        onErrorFallback: (dynamic _) =>
            Text(_plainFallbackText(formula), style: mathTextStyle),
      );
    }
    return Text(_plainFallbackText(formula), style: mathTextStyle);
  }

  String _normalizeFormulaForRetry(String raw) {
    if (raw.isEmpty) return raw;
    var out = _normalizeUnicodeScript(raw)
        .replaceAll('×', r'\times ')
        .replaceAll('÷', r'\div ')
        .replaceAll('·', r'\cdot ')
        .replaceAll('∙', r'\cdot ')
        .replaceAll('−', '-')
        .replaceAll('≤', r'\le ')
        .replaceAll('≥', r'\ge ')
        .replaceAll('¼', r'\frac{1}{4}')
        .replaceAll('½', r'\frac{1}{2}')
        .replaceAll('¾', r'\frac{3}{4}')
        .replaceAll('⅓', r'\frac{1}{3}')
        .replaceAll('⅔', r'\frac{2}{3}')
        .replaceAll('⅕', r'\frac{1}{5}')
        .replaceAll('⅖', r'\frac{2}{5}')
        .replaceAll('⅗', r'\frac{3}{5}')
        .replaceAll('⅘', r'\frac{4}{5}')
        .replaceAll('⅙', r'\frac{1}{6}')
        .replaceAll('⅚', r'\frac{5}{6}')
        .replaceAll('⅛', r'\frac{1}{8}')
        .replaceAll('⅜', r'\frac{3}{8}')
        .replaceAll('⅝', r'\frac{5}{8}')
        .replaceAll('⅞', r'\frac{7}{8}');
    out = _dropUnmatchedCurlyBraces(out);
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _plainFallbackText(String raw) {
    return raw
        .replaceAll(RegExp(r'\\'), '')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeUnicodeScript(String input) {
    if (input.isEmpty) return input;
    const supMap = <String, String>{
      '⁰': '0',
      '¹': '1',
      '²': '2',
      '³': '3',
      '⁴': '4',
      '⁵': '5',
      '⁶': '6',
      '⁷': '7',
      '⁸': '8',
      '⁹': '9',
      '⁺': '+',
      '⁻': '-',
      '⁼': '=',
      '⁽': '(',
      '⁾': ')',
      'ⁿ': 'n',
      'ˣ': 'x',
    };
    const subMap = <String, String>{
      '₀': '0',
      '₁': '1',
      '₂': '2',
      '₃': '3',
      '₄': '4',
      '₅': '5',
      '₆': '6',
      '₇': '7',
      '₈': '8',
      '₉': '9',
      '₊': '+',
      '₋': '-',
      '₌': '=',
      '₍': '(',
      '₎': ')',
      'ₓ': 'x',
    };
    final sb = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final sup = supMap[ch];
      if (sup != null) {
        sb.write('^{');
        sb.write(sup);
        sb.write('}');
        continue;
      }
      final sub = subMap[ch];
      if (sub != null) {
        sb.write('_{');
        sb.write(sub);
        sb.write('}');
        continue;
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  String _dropUnmatchedCurlyBraces(String raw) {
    if (raw.isEmpty) return raw;
    final out = <String>[];
    final openIndices = <int>[];
    for (int i = 0; i < raw.length; i += 1) {
      final ch = raw[i];
      if (ch == '{') {
        openIndices.add(out.length);
        out.add(ch);
        continue;
      }
      if (ch == '}') {
        if (openIndices.isNotEmpty) {
          openIndices.removeLast();
          out.add(ch);
        }
        continue;
      }
      out.add(ch);
    }
    for (final idx in openIndices) {
      out[idx] = '';
    }
    return out.join();
  }

  bool _isFractionFormula(String formula) {
    return formula.contains(r'\frac') ||
        formula.contains(r'\dfrac') ||
        RegExp(r'(^|[^\\])\d+\s*/\s*\d+').hasMatch(formula);
  }

  /// Inline `\(...\)` 로 들어와도 행렬·다줄 환경은 [MathStyle.display]로 그려야 가로로 눌리지 않는다.
  bool _latexFormulaPrefersDisplay(String formula) {
    if (formula.isEmpty) return false;
    final f = formula.toLowerCase();
    return f.contains(r'\begin{matrix') ||
        f.contains(r'\begin{pmatrix') ||
        f.contains(r'\begin{bmatrix') ||
        f.contains(r'\begin{vmatrix') ||
        f.contains(r'\begin{Vmatrix') ||
        f.contains(r'\begin{array') ||
        f.contains(r'\begin{aligned') ||
        f.contains(r'\begin{align') ||
        f.contains(r'\begin{cases') ||
        f.contains(r'\begin{split') ||
        f.contains(r'\begin{gather') ||
        f.contains(r'\begin{multline') ||
        f.contains(r'\substack') ||
        (f.contains(r'\begin{') && f.contains(r'\\'));
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
