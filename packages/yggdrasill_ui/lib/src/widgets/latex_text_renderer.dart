import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// `$$...$$` 블록이 가용 폭을 초과할 때의 처리 방식.
/// - [scroll]: 기본값. 가로 스크롤 가능한 [SingleChildScrollView]로 감싼다.
/// - [scaleDown]: 가로 스크롤 없이 [FittedBox]로 축소(필요 시)한다.
enum DisplayMathOverflow { scroll, scaleDown }

class LatexTextRenderer extends StatelessWidget {
  static const String v2TextFontFamily = 'KoPubWorldBatangPro';

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
  final DisplayMathOverflow displayMathOverflow;

  /// `$…$`도 문장 속 수식으로 그린다.
  final bool dollarMath;

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
    this.displayMathOverflow = DisplayMathOverflow.scroll,
    this.dollarMath = false,
  });

  static bool hasLatex(String raw) {
    if (raw.isEmpty) return false;
    return _displayRegex.hasMatch(raw) || _inlineRegex.hasMatch(raw);
  }

  /// `$…$`를 `\(…\)`로 바꾼다. `$$…$$`·`\(…\)`는 그대로 두고, 닫히지 않은 `$`는 글자로 남긴다.
  static String inlineDollarMath(String raw) {
    if (!raw.contains(r'$')) return raw;
    final out = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final close = raw.startsWith(r'$$', i)
          ? r'$$'
          : raw.startsWith(r'\(', i)
              ? r'\)'
              : null;
      if (close != null) {
        final end = raw.indexOf(close, i + 2);
        if (end < 0) {
          out.write(raw.substring(i));
          break;
        }
        out.write(raw.substring(i, end + close.length));
        i = end + close.length;
        continue;
      }
      if (raw[i] == r'$') {
        final end = raw.indexOf(r'$', i + 1);
        if (end < 0) {
          out.write(raw.substring(i));
          break;
        }
        out
          ..write(r'\(')
          ..write(raw.substring(i + 1, end))
          ..write(r'\)');
        i = end + 1;
        continue;
      }
      out.write(raw[i]);
      i += 1;
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final text = dollarMath ? inlineDollarMath(this.text) : this.text;
    final mergedStyle = DefaultTextStyle.of(context).style.merge(style);
    final effectiveStyle = hasLatex(text)
        ? mergedStyle.copyWith(fontFamily: v2TextFontFamily)
        : mergedStyle;
    final displayMathTextStyle = _mathEngineStyle(
      _scaleMathTextStyle(effectiveStyle, displayMathScale),
    );
    if (!enableDisplayMath || !_displayRegex.hasMatch(text)) {
      return _buildInlineText(text, effectiveStyle);
    }

    final parts = _splitDisplayParts(text);
    final children = <Widget>[];
    for (final part in parts) {
      if (part.isDisplayMath) {
        final formula = _normalizeFormulaForRender(part.content.trim());
        if (formula.isEmpty) {
          continue;
        }
        final mathWidget = Math.tex(
          formula,
          mathStyle: MathStyle.display,
          textStyle: displayMathTextStyle,
          onErrorFallback: (dynamic _) => _buildMathFallback(
            formula,
            displayMathTextStyle,
            mathStyle: MathStyle.display,
          ),
        );
        final Widget boxed;
        switch (displayMathOverflow) {
          case DisplayMathOverflow.scaleDown:
            boxed = SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: _fittedBoxAlignment(crossAxisAlignment),
                child: mathWidget,
              ),
            );
            break;
          case DisplayMathOverflow.scroll:
            boxed = SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: mathWidget,
            );
            break;
        }
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: blockVerticalPadding),
            child: boxed,
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
      final formula = _normalizeFormulaForRender((match.group(1) ?? '').trim());
      if (formula.isEmpty) {
        spans.add(TextSpan(text: fullMatch));
      } else {
        final useDisplayLayout = _latexFormulaPrefersDisplay(formula);
        final fractionFormula =
            !useDisplayLayout && _isFractionFormula(formula);
        final nestedFraction = !useDisplayLayout &&
            fractionFormula &&
            RegExp(r'\\left|\\right').hasMatch(formula);
        final scaledStyle = _mathEngineStyle(
          _scaleMathTextStyle(
            effectiveStyle,
            useDisplayLayout
                ? displayMathScale
                : (fractionFormula
                    ? fractionInlineMathScale
                    : inlineMathScale),
          ),
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
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: useDisplayLayout ? 3.0 : 0.0,
              ),
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

  Alignment _fittedBoxAlignment(CrossAxisAlignment cross) {
    switch (cross) {
      case CrossAxisAlignment.end:
        return Alignment.centerRight;
      case CrossAxisAlignment.center:
      case CrossAxisAlignment.baseline:
      case CrossAxisAlignment.stretch:
        return Alignment.center;
      case CrossAxisAlignment.start:
        return Alignment.centerLeft;
    }
  }

  TextStyle _scaleMathTextStyle(TextStyle base, double scale) {
    final fontSize = base.fontSize;
    if (fontSize == null || fontSize <= 0) return base;
    return base.copyWith(fontSize: fontSize * scale);
  }

  /// `flutter_math_fork`는 [FontWeight.normal]이 아니면 수식 기울임을 끄고
  /// 정자체 `KaTeX_Main`으로 그린다. 주변 글자 두께는 유지하고 수식 글리프만
  /// 보통 굵기로 넘겨 V2와 같은 기울임 변수가 나오게 한다.
  TextStyle _mathEngineStyle(TextStyle style) {
    if (style.fontWeight == null || style.fontWeight == FontWeight.normal) {
      return style;
    }
    return style.copyWith(fontWeight: FontWeight.normal);
  }

  Widget _buildMathFallback(
    String formula,
    TextStyle mathTextStyle, {
    required MathStyle mathStyle,
  }) {
    final arrayTable = _buildArrayTableFallback(formula, mathTextStyle);
    if (arrayTable != null) return arrayTable;
    final textFraction = _buildTextFractionFallback(formula, mathTextStyle);
    if (textFraction != null) return textFraction;
    final normalized = _normalizeFormulaForRetry(formula);
    if (normalized.isNotEmpty && normalized != formula) {
      return Math.tex(
        normalized,
        textStyle: mathTextStyle,
        mathStyle: mathStyle,
        onErrorFallback: (dynamic _) =>
            _buildArrayTableFallback(normalized, mathTextStyle) ??
            Text(_plainFallbackText(formula), style: mathTextStyle),
      );
    }
    return Text(_plainFallbackText(formula), style: mathTextStyle);
  }

  Widget? _buildArrayTableFallback(String formula, TextStyle style) {
    final m = RegExp(
      r'^\s*\\begin\{array\}\{([^}]*)\}([\s\S]*?)\\end\{array\}\s*$',
    ).firstMatch(formula);
    if (m == null) return null;
    final spec = (m.group(1) ?? '').replaceAll(' ', '');
    final body = (m.group(2) ?? '').trim();
    if (body.isEmpty) return null;

    final vBorderAfterCol = <int>{};
    var colIndex = -1;
    for (var i = 0; i < spec.length; i += 1) {
      final ch = spec[i];
      if (ch == 'c' || ch == 'l' || ch == 'r') {
        colIndex += 1;
      } else if (ch == '|' && colIndex >= 0) {
        vBorderAfterCol.add(colIndex);
      }
    }

    final rawRows = body.split(r'\\');
    final rows = <List<String>>[];
    final hBorderBeforeRow = <int>{};
    for (var rawRow in rawRows) {
      var r = rawRow.trim();
      if (r.isEmpty) continue;
      while (r.startsWith(r'\hline')) {
        hBorderBeforeRow.add(rows.length);
        r = r.substring(6).trim();
      }
      if (r.isEmpty) continue;
      rows.add([for (final cell in r.split('&')) cell.trim()]);
    }
    if (rows.isEmpty) return null;

    var maxCols = 0;
    for (final r in rows) {
      if (r.length > maxCols) maxCols = r.length;
    }
    if (maxCols == 0) return null;

    final borderColor = (style.color ?? const Color(0xFFEAF2F2))
        .withValues(alpha: 0.55);
    final borderSide = BorderSide(color: borderColor, width: 1.1);
    final cellStyle = style.copyWith(fontFamily: v2TextFontFamily, height: 1.15);

    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (var ri = 0; ri < rows.length; ri += 1)
          TableRow(
            decoration: hBorderBeforeRow.contains(ri)
                ? BoxDecoration(border: Border(top: borderSide))
                : null,
            children: [
              for (var ci = 0; ci < maxCols; ci += 1)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: vBorderAfterCol.contains(ci)
                      ? BoxDecoration(border: Border(right: borderSide))
                      : null,
                  alignment: Alignment.center,
                  child: ci < rows[ri].length && rows[ri][ci].isNotEmpty
                      ? Math.tex(
                          rows[ri][ci],
                          textStyle: _mathEngineStyle(cellStyle),
                          mathStyle: MathStyle.text,
                          onErrorFallback: (_) =>
                              Text(_plainFallbackText(rows[ri][ci]), style: cellStyle),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
  }

  String _normalizeFormulaForRender(String raw) {
    final input = _normalizeElasticDelimitersForFlutter(
      _normalizeColonCommand(raw.trim()),
    );
    if (input.isEmpty) return input;
    final match = RegExp(
      r'^\(?\s*(\\(?:dfrac|tfrac|frac)\s*\{\s*(?:\\(?:text|mathrm)\s*\{[^{}]+\}|[^{}]+)\s*\}\s*\{\s*(?:\\(?:text|mathrm)\s*\{[^{}]+\}|[^{}]+)\s*\})\s*\)?$',
    ).firstMatch(input);
    if (match == null) return input;
    final hasParens = input.startsWith('(') && input.endsWith(')');
    final fraction = (match.group(1) ?? input).replaceFirst(
      RegExp(r'^\\(?:dfrac|tfrac|frac)\b'),
      r'\dfrac',
    );
    if (!hasParens) return fraction;
    return '\\left($fraction\\right)';
  }

  Widget? _buildTextFractionFallback(String formula, TextStyle style) {
    final input = formula.trim();
    final match = RegExp(
      r'^(?:\\left)?\(?\s*\\(?:dfrac|tfrac|frac)\s*\{\s*(?:\\(?:text|mathrm)\s*\{([^{}]+)\}|([^{}]+))\s*\}\s*\{\s*(?:\\(?:text|mathrm)\s*\{([^{}]+)\}|([^{}]+))\s*\}\s*(?:\\right)?\)?$',
    ).firstMatch(input);
    if (match == null) return null;
    final numerator = (match.group(1) ?? match.group(2) ?? '').trim();
    final denominator = (match.group(3) ?? match.group(4) ?? '').trim();
    if (numerator.isEmpty || denominator.isEmpty) return null;
    final showParens = input.startsWith('(') || input.startsWith(r'\left(');
    final textStyle = style.copyWith(height: 1.05);
    final fraction = IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(numerator, textAlign: TextAlign.center, style: textStyle),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 1.5),
            color: textStyle.color ?? Colors.black,
          ),
          Text(denominator, textAlign: TextAlign.center, style: textStyle),
        ],
      ),
    );
    if (!showParens) return fraction;
    final parenStyle = style.copyWith(fontSize: (style.fontSize ?? 14) * 2.35);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('(', style: parenStyle),
        fraction,
        Text(')', style: parenStyle),
      ],
    );
  }

  String _normalizeFormulaForRetry(String raw) {
    if (raw.isEmpty) return raw;
    var out = _normalizeElasticDelimitersForFlutter(
      _normalizeUnicodeScript(_normalizeColonCommand(raw)),
    )
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

  String _normalizeElasticDelimitersForFlutter(String raw) {
    if (raw.isEmpty) return raw;
    return raw.replaceAllMapped(
      RegExp(r'\\left\s*([\[\]\(\)\{\}\|.])'),
      (m) {
        final delimiter = m.group(1) ?? '';
        if (delimiter == '.') return '';
        return delimiter;
      },
    ).replaceAllMapped(
      RegExp(r'\\right\s*([\[\]\(\)\{\}\|.])'),
      (m) {
        final delimiter = m.group(1) ?? '';
        if (delimiter == '.') return '';
        return delimiter;
      },
    );
  }

  String _normalizeColonCommand(String raw) {
    return raw
        .replaceAll(r'\YggLabelColon', r'\colon')
        .replaceAll(r'\colon', r'\mathord{\text{:}}\,');
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

  /// Inline `\(...\)` 로 들어와도 분수·행렬은 [MathStyle.display]로 쌓아 그린다.
  bool _latexFormulaPrefersDisplay(String formula) {
    if (formula.isEmpty) return false;
    final f = formula.toLowerCase();
    if (f.contains(r'\frac') ||
        f.contains(r'\dfrac') ||
        f.contains(r'\tfrac') ||
        f.contains(r'\displaystyle') ||
        f.contains(r'\sqrt') ||
        f.contains(r'\sum') ||
        f.contains(r'\int') ||
        f.contains(r'\binom') ||
        f.contains(r'\over')) {
      return true;
    }
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
