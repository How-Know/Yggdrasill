import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';
import '../../../widgets/latex_text_renderer.dart';

class ProblemBankManagerPreviewPaper extends StatelessWidget {
  const ProblemBankManagerPreviewPaper({
    super.key,
    required this.question,
    this.figureUrlsByPath = const <String, String>{},
    this.expanded = false,
    this.scrollable = true,
    this.bordered = true,
    this.shadow = true,
    this.showQuestionNumberPrefix = false,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
  });

  static const String _previewKoreanFontFamily = 'HCRBatang';
  static const double _previewMathScale = 1.10;
  static const double _previewFractionMathScale = _previewMathScale;

  static const double _pdfQuestionNumberLaneWidth = 34.0;
  static const double _pdfQuestionNumberGap = 8.0;
  static const double _pdfQuestionNumberTopOffset = 2.0;

  static final _structuralMarkerRegex = RegExp(r'\[(박스시작|박스끝|문단)\]');
  static final RegExp _figureMarkerRegex =
      RegExp(r'\[(?:그림|도형|도표|표)\]', caseSensitive: false);
  static final _boxMarkerStartRegex = RegExp(r'\[박스시작\]');
  static final _boxMarkerEndRegex = RegExp(r'\[박스끝\]');
  static final _paragraphMarkerRegex = RegExp(r'\[문단\]');

  final LearningProblemQuestion question;
  final Map<String, String> figureUrlsByPath;
  final bool expanded;
  final bool scrollable;
  final bool bordered;
  final bool shadow;
  final bool showQuestionNumberPrefix;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    return _buildPdfPreviewPaperContent(question);
  }

  String _normalizePreviewLine(String raw) {
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _normalizePreviewMultiline(String raw) {
    final src = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = src
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return lines.join('\n');
  }

  static const Map<String, String> _unicodeSuperscriptMap = {
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

  static const Map<String, String> _unicodeSubscriptMap = {
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

  String _normalizeUnicodeScriptTokens(String input) {
    if (input.isEmpty) return input;
    final sb = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final sup = _unicodeSuperscriptMap[ch];
      if (sup != null) {
        sb.write('^{');
        sb.write(sup);
        sb.write('}');
        continue;
      }
      final sub = _unicodeSubscriptMap[ch];
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

  String _normalizeLatexPreview(String raw) {
    String out =
        _normalizeUnicodeScriptTokens(raw.replaceAll(RegExp(r'`+'), ''));
    out = out
        .replaceAll('×', r'\times ')
        .replaceAll('÷', r'\div ')
        .replaceAll('·', r'\cdot ')
        .replaceAll('∙', r'\cdot ')
        .replaceAll('−', '-')
        .replaceAll('≤', r'\le ')
        .replaceAll('≥', r'\ge ')
        .replaceAll('∥', r'\mathbin{/\mkern-2mu/}')
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
        .replaceAll('⅞', r'\frac{7}{8}')
        .replaceAll(RegExp(r'\{rm\{([^}]*)\}\}it', caseSensitive: false),
            r'\\mathrm{$1}')
        .replaceAll(
            RegExp(r'rm\{([^}]*)\}it', caseSensitive: false), r'\\mathrm{$1}')
        .replaceAllMapped(
          RegExp(
            r'(^|[^\\])left\s*(?=[\[\]\(\)\{\}\|.])',
            caseSensitive: false,
          ),
          (m) => '${m.group(1) ?? ''}${r'\left'}',
        )
        .replaceAllMapped(
          RegExp(
            r'(^|[^\\])right\s*(?=[\[\]\(\)\{\}\|.])',
            caseSensitive: false,
          ),
          (m) => '${m.group(1) ?? ''}${r'\right'}',
        )
        .replaceAll(RegExp(r'\btimes\b', caseSensitive: false), r'\times ')
        .replaceAll(RegExp(r'\bdiv\b', caseSensitive: false), r'\div ')
        .replaceAll(RegExp(r'\ble\b', caseSensitive: false), r'\le ')
        .replaceAll(RegExp(r'\bge\b', caseSensitive: false), r'\ge ');
    out = out.replaceAll(
      RegExp(r'\\parallel(?![a-zA-Z])'),
      r'\mathbin{/\mkern-2mu/}',
    );

    for (int i = 0; i < 4; i += 1) {
      final next = out
          .replaceAllMapped(
            RegExp(r'\{([^{}]+)\}\s*\\over\s*\{([^{}]+)\}'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          )
          .replaceAllMapped(
            RegExp(r'([\-]?\d+(?:\.\d+)?)\s*\\over\s*\{([^{}]+)\}'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          )
          .replaceAllMapped(
            RegExp(r'([A-Za-z])\s*\\over\s*([A-Za-z0-9]+)'),
            (m) => '\\frac{${m.group(1)!.trim()}}{${m.group(2)!.trim()}}',
          );
      if (next == out) break;
      out = next;
    }

    out = out
        .replaceAll(RegExp(r'\\over'), '/')
        .replaceAll(RegExp(r'\\{2,}'), r'\')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return out;
  }

  String _sanitizeLatexForMathTex(String raw) {
    String out = _normalizeLatexPreview(raw);
    out = out
        .replaceAllMapped(
          RegExp(r'\\left\s*([\[\]\(\)\{\}\|])'),
          (m) {
            final d = m.group(1) ?? '';
            if (d == '{') return r'\left\{';
            if (d == '}') return r'\left\}';
            return r'\left' + d;
          },
        )
        .replaceAllMapped(
          RegExp(r'\\right\s*([\[\]\(\)\{\}\|])'),
          (m) {
            final d = m.group(1) ?? '';
            if (d == '{') return r'\right\{';
            if (d == '}') return r'\right\}';
            return r'\right' + d;
          },
        )
        .replaceAll(RegExp(r'\\left\{'), r'\left\{')
        .replaceAll(RegExp(r'\\right\}'), r'\right\}');
    out = _balanceCurlyBracesForPreview(out);

    final leftCount =
        RegExp(r'\\left(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    final rightCount =
        RegExp(r'\\right(?=[\\\[\]\(\)\{\}\|.])').allMatches(out).length;
    if (leftCount != rightCount) {
      out = out.replaceAll(r'\left', '').replaceAll(r'\right', '');
    }
    return out.trim();
  }

  String _balanceCurlyBracesForPreview(String raw) {
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

  bool _hasBalancedCurlyBraces(String raw) {
    int depth = 0;
    for (int i = 0; i < raw.length; i += 1) {
      final ch = raw[i];
      if (ch == '{') depth += 1;
      if (ch == '}') {
        depth -= 1;
        if (depth < 0) return false;
      }
    }
    return depth == 0;
  }

  bool _isLikelyLatexParseUnsafe(String raw) {
    if (raw.trim().isEmpty) return true;
    if (!_hasBalancedCurlyBraces(raw)) return true;
    final leftCount = RegExp(r'\\left').allMatches(raw).length;
    final rightCount = RegExp(r'\\right').allMatches(raw).length;
    if (leftCount != rightCount) return true;
    return false;
  }

  bool _containsFractionExpression(String raw) {
    return raw.contains(r'\frac') ||
        raw.contains(r'\dfrac') ||
        raw.contains(r'\tfrac') ||
        RegExp(r'(^|[^\\])\d+\s*/\s*\d+').hasMatch(raw);
  }

  bool _containsNestedFractionExpression(String raw) {
    if (!_containsFractionExpression(raw)) return false;
    return RegExp(r'\\left|\\right').hasMatch(raw) ||
        RegExp(r'\([^()]*\([^()]+\)').hasMatch(raw) ||
        RegExp(r'\[[^\[\]]*\[[^\[\]]+\]').hasMatch(raw);
  }

  String _latexToPlainPreview(String raw) {
    var out = raw;
    for (int i = 0; i < 4; i += 1) {
      final next = out.replaceAllMapped(
        RegExp(r'\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}'),
        (m) => '${m.group(1)}/${m.group(2)}',
      );
      if (next == out) break;
      out = next;
    }
    out = out
        .replaceAll(r'\times', '×')
        .replaceAll(r'\div', '÷')
        .replaceAll(r'\le', '≤')
        .replaceAll(r'\ge', '≥')
        .replaceAll(RegExp(r'\\left|\\right'), '')
        .replaceAll(RegExp(r'\\mathrm\{([^{}]+)\}'), r'$1')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll(RegExp(r'\\'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return out;
  }

  bool _looksLikeMathCandidate(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return false;
    if (RegExp(r'[가-힣]').hasMatch(input)) return false;
    return RegExp(r'[A-Za-z0-9=^_{}\\]|\\times|\\over|\\le|\\ge|\\frac|\\dfrac')
        .hasMatch(input);
  }

  bool _isPurePunctuationSegment(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return true;
    return RegExp(r'^[\.,;:!?<>\(\)\[\]\{\}\-~"' "'" r'`|\\/]+$')
        .hasMatch(compact);
  }

  void _appendPreviewMathToken(
    StringBuffer buffer,
    String latex, {
    required bool compactFractions,
  }) {
    if (_containsFractionExpression(latex)) {
      final boostedLatex = _promoteFractionsForPreview(latex);
      final fracMode = compactFractions ? r'\textstyle' : r'\displaystyle';
      buffer.write('\\($fracMode ');
      buffer.write(boostedLatex);
      buffer.write(r'\)');
      return;
    }
    buffer.write(r'\(');
    buffer.write(latex);
    buffer.write(r'\)');
  }

  String _promoteFractionsForPreview(String latex) {
    var out = latex;
    out = out.replaceAllMapped(
      RegExp(r'\\(?:dfrac|tfrac|frac)\s*(?=\{)'),
      (_) => r'\dfrac',
    );
    out = out.replaceAllMapped(
      RegExp(r'(?<![\\\w])(-?\d+(?:\.\d+)?)\s*/\s*(-?\d+(?:\.\d+)?)(?![\w])'),
      (m) => r'\dfrac{${m.group(1) ?? ' '}}{${m.group(2) ?? ''}}',
    );
    return out;
  }

  String _buildTokenizedMathMarkup(
    String latex, {
    required bool compactFractions,
  }) {
    final hasStructuredCommand = RegExp(
      r'\\(?:left|right|frac|dfrac|sqrt|sum|int|overline|mathrm|text|begin|end)',
    ).hasMatch(latex);
    final hasScriptOrGrouping = RegExp(r'[{}^_]').hasMatch(latex);
    if (!latex.contains(' ') || hasStructuredCommand || hasScriptOrGrouping) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    final parts = latex
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    final tokenized = <String>[];
    for (final token in parts) {
      final isOperatorToken = RegExp(
        r'^(?:=|[+\-*/<>]|\\times|\\div|\\cdot|\\le|\\ge)+$',
      ).hasMatch(token);
      final tokenIsMath = isOperatorToken || _looksLikeMathCandidate(token);
      if (tokenIsMath &&
          !_isPurePunctuationSegment(token) &&
          !_isLikelyLatexParseUnsafe(token)) {
        final sb = StringBuffer();
        _appendPreviewMathToken(sb, token, compactFractions: compactFractions);
        tokenized.add(sb.toString());
      } else {
        tokenized.add(token);
      }
    }
    if (tokenized.isEmpty) {
      final one = StringBuffer();
      _appendPreviewMathToken(one, latex, compactFractions: compactFractions);
      return one.toString();
    }
    return tokenized.join(' ');
  }

  String _toPreviewMathMarkup(
    String raw, {
    bool forceMathTokenWrap = false,
    bool compactFractions = true,
  }) {
    final input = raw;
    if (input.trim().isEmpty) return '';
    final buffer = StringBuffer();
    int lastIndex = 0;
    final nonKoreanSegments = RegExp(r'[^가-힣]+');
    for (final match in nonKoreanSegments.allMatches(input)) {
      if (match.start > lastIndex) {
        buffer.write(input.substring(lastIndex, match.start));
      }
      final segment = input.substring(match.start, match.end);
      final leading = RegExp(r'^\s*').stringMatch(segment) ?? '';
      final trailing = RegExp(r'\s*$').stringMatch(segment) ?? '';
      final core = segment.trim();
      if (core.isEmpty) {
        buffer.write(segment);
        lastIndex = match.end;
        continue;
      }
      final latex = _sanitizeLatexForMathTex(core);
      final compact = latex.replaceAll(RegExp(r'[\s\.,;:!?()\[\]<>]'), '');
      final hasMathOperator = RegExp(
              r'[=^_]|[+\-*/<>]|\\times|\\over|\\div|\\le|\\ge|\\frac|\\dfrac|\\sqrt|\\left|\\right|\\sum|\\int|\\pi|\\theta|\\sin|\\cos|\\tan|\\log')
          .hasMatch(latex);
      final hasMathToken =
          hasMathOperator || RegExp(r'[A-Za-z0-9]').hasMatch(latex);
      final looksJustNumbering =
          RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩0-9.\-]+$').hasMatch(compact);
      final isViewMarker = RegExp(r'보\s*기').hasMatch(core);
      final shouldWrap = compact.isNotEmpty &&
          (forceMathTokenWrap || !looksJustNumbering) &&
          !isViewMarker &&
          !_isPurePunctuationSegment(latex) &&
          _looksLikeMathCandidate(latex) &&
          hasMathToken &&
          !_isLikelyLatexParseUnsafe(latex);
      if (shouldWrap) {
        buffer.write(leading);
        if (forceMathTokenWrap) {
          buffer.write(
            _buildTokenizedMathMarkup(
              latex,
              compactFractions: compactFractions,
            ),
          );
        } else {
          _appendPreviewMathToken(
            buffer,
            latex,
            compactFractions: compactFractions,
          );
        }
        buffer.write(trailing);
      } else {
        buffer.write(leading);
        if (_looksLikeMathCandidate(latex) && forceMathTokenWrap) {
          final fallbackLatex =
              _sanitizeLatexForMathTex(_latexToPlainPreview(latex));
          if (fallbackLatex.isNotEmpty &&
              !_isPurePunctuationSegment(fallbackLatex) &&
              !_isLikelyLatexParseUnsafe(fallbackLatex)) {
            _appendPreviewMathToken(
              buffer,
              fallbackLatex,
              compactFractions: compactFractions,
            );
          } else {
            buffer.write(_latexToPlainPreview(latex));
          }
        } else if (_looksLikeMathCandidate(latex)) {
          buffer.write(_latexToPlainPreview(latex));
        } else {
          buffer.write(core);
        }
        buffer.write(trailing);
      }
      lastIndex = match.end;
    }
    if (lastIndex < input.length) {
      buffer.write(input.substring(lastIndex));
    }
    return buffer.toString();
  }

  double _choicePreviewLineHeight(String raw) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) return 1.94;
    if (_containsFractionExpression(latex)) return 1.82;
    return 1.60;
  }

  double _denseMathLineHeight(String raw, {double normal = 1.66}) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) return normal + 0.32;
    if (_containsFractionExpression(latex)) return normal + 0.20;
    if (RegExp(r'[A-Za-z0-9]').hasMatch(latex)) return normal + 0.06;
    return normal;
  }

  double _mathSymmetricVerticalPadding(
    String raw, {
    bool compact = false,
  }) {
    final latex = _sanitizeLatexForMathTex(raw);
    if (_containsNestedFractionExpression(latex)) {
      return compact ? 1.6 : 2.4;
    }
    if (_containsFractionExpression(latex)) {
      return compact ? 1.2 : 1.8;
    }
    return compact ? 0.25 : 0.35;
  }

  bool _looksLikeBoxedStemLine(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'^\(단[,，:]?').hasMatch(input)) return true;
    if (RegExp(r'^\|.+\|').hasMatch(input)) return true;
    return false;
  }

  bool _looksLikeBoxedConditionStart(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'옆으로\s*이웃한').hasMatch(input)) return true;
    if (RegExp(r'바로\s*위의?\s*칸').hasMatch(input)) return true;
    if (RegExp(r'^\(단[,，:]?').hasMatch(input)) return true;
    if (RegExp(r'^\|.+\|').hasMatch(input)) return true;
    return false;
  }

  bool _looksLikeBoxedConditionContinuation(String line) {
    final input = _normalizePreviewLine(line);
    if (input.isEmpty) return false;
    if (RegExp(r'일\s*때').hasMatch(input)) return true;
    if (RegExp(r'예\)$').hasMatch(input)) return true;
    if (RegExp(r'바로\s*위의?\s*칸').hasMatch(input)) return true;
    if (_figureMarkerRegex.hasMatch(input)) return true;
    return false;
  }

  List<List<String>> _boxedStemGroups(String raw) {
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map(_normalizePreviewLine)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const <List<String>>[];
    final groups = <List<String>>[];
    List<String> current = <String>[];
    bool inBoxedRegion = false;
    for (final line in lines) {
      if (!inBoxedRegion && _looksLikeBoxedConditionStart(line)) {
        inBoxedRegion = true;
        current.add(line);
        continue;
      }
      if (inBoxedRegion) {
        if (_looksLikeBoxedConditionContinuation(line) ||
            _looksLikeBoxedStemLine(line) ||
            _figureMarkerRegex.hasMatch(line)) {
          current.add(line);
          continue;
        }
        if (current.isNotEmpty) {
          groups.add(List<String>.from(current));
        }
        current = <String>[];
        inBoxedRegion = false;
        continue;
      }
      if (_looksLikeBoxedStemLine(line)) {
        current.add(line);
        continue;
      }
      if (current.isNotEmpty) {
        if (current.length >= 2) {
          groups.add(List<String>.from(current));
        }
        current = <String>[];
      }
    }
    if (current.isNotEmpty && (inBoxedRegion || current.length >= 2)) {
      groups.add(List<String>.from(current));
    }
    return groups;
  }

  List<String> _viewBlockPreviewLines(LearningProblemQuestion q,
      {int max = 6}) {
    final normalizedStem = _stripPreviewStemDecorations(
      q,
      _normalizePreviewMultiline(q.renderedStem),
    );
    final markerNormalized = normalizedStem
        .replaceAll(_structuralMarkerRegex, ' ')
        .replaceAll(RegExp(r'<\s*보\s*기>'), '<보기>');
    final lines = markerNormalized
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const <String>[];
    final lastMarker = markerNormalized.lastIndexOf('<보기>');
    if (lastMarker >= 0) {
      final tail =
          markerNormalized.substring(lastMarker + '<보기>'.length).trim();
      final rawParts = tail.split(RegExp(r'(?=[ㄱ-ㅎ]\.)'));
      final parts = <String>[];
      for (final part in rawParts) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        if (RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(trimmed)) {
          parts.add(trimmed);
        } else if (parts.isNotEmpty) {
          parts[parts.length - 1] = '${parts.last} $trimmed';
        }
        if (parts.length >= max) break;
      }
      if (parts.isNotEmpty) {
        return <String>['<보기>', ...parts];
      }
    }

    final markerIdx = lines.indexWhere((line) => line.contains('<보기>'));
    int start = markerIdx >= 0
        ? markerIdx + 1
        : lines.indexWhere((line) => RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line));
    if (start < 0) return const <String>[];

    final out = <String>[];
    if (markerIdx >= 0) out.add('<보기>');
    for (int i = start; i < lines.length; i += 1) {
      final line = lines[i];
      if (RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(line)) break;
      if (RegExp(r'^[ㄱ-ㅎ]\.').hasMatch(line)) {
        out.add(line);
      } else if (out.length > (markerIdx >= 0 ? 1 : 0)) {
        out[out.length - 1] = '${out.last} $line';
      }
      if (out.length >= max + (markerIdx >= 0 ? 1 : 0)) break;
    }
    return out;
  }

  String _stripPreviewStemDecorations(LearningProblemQuestion q, String raw) {
    var out = _normalizePreviewMultiline(raw);
    if (out.isEmpty) return '';
    out = out.replaceFirst(RegExp(r'^(\s*\[(문단|박스끝)\]\s*)+'), '');
    out = out.replaceAll(RegExp(r'^\$1\s*'), '');
    out = out.replaceAll(RegExp(r'\$1(?=<\s*보\s*기>)'), '');
    final qn = q.questionNumber.trim();
    if (qn.isNotEmpty) {
      final lines = out.split('\n');
      if (lines.isNotEmpty) {
        lines[0] = _stripLeadingQuestionNumberToken(lines[0], qn);
        out = lines
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join('\n');
      }
    }
    out = out.replaceFirst(RegExp(r'(\s*\[(문단|박스시작)\]\s*)+$'), '');
    return _normalizePreviewMultiline(out);
  }

  String _choiceLabelByIndex(int index) {
    const labels = <String>['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    if (index >= 0 && index < labels.length) return labels[index];
    return '${index + 1}';
  }

  List<LearningProblemChoice> _previewChoicesOf(LearningProblemQuestion q) {
    final source =
        q.objectiveChoices.length >= 2 ? q.objectiveChoices : q.choices;
    final out = <LearningProblemChoice>[];
    for (var i = 0; i < source.length; i += 1) {
      final text = _normalizePreviewLine(source[i].text);
      if (text.isEmpty) continue;
      final label = source[i].label.trim().isNotEmpty
          ? source[i].label.trim()
          : _choiceLabelByIndex(i);
      out.add(LearningProblemChoice(label: label, text: text));
    }
    return out;
  }

  Map<String, dynamic>? _latestFigureAssetOf(LearningProblemQuestion q) {
    final assets = q.figureAssets.toList(growable: true);
    if (assets.isEmpty) return null;
    // approved=true 우선, 그다음 created_at 내림차순.
    assets.sort((a, b) {
      final aApproved = a['approved'] == true ? 1 : 0;
      final bApproved = b['approved'] == true ? 1 : 0;
      if (aApproved != bApproved) return bApproved - aApproved;
      final aa = '${a['created_at'] ?? ''}';
      final bb = '${b['created_at'] ?? ''}';
      return bb.compareTo(aa);
    });
    return assets.first;
  }

  List<Map<String, dynamic>> _orderedFigureAssetsOf(LearningProblemQuestion q) {
    return q.orderedFigureAssets;
  }

  static const double _figureScaleMin = 0.3;
  static const double _figureScaleMax = 2.2;

  double _normalizeFigureScale(double value) {
    if (!value.isFinite) return 1.0;
    return value.clamp(_figureScaleMin, _figureScaleMax).toDouble();
  }

  Map<String, double> _figureRenderScaleMapOf(LearningProblemQuestion q) {
    final raw = q.meta['figure_render_scales'];
    if (raw is! Map) return const <String, double>{};
    final out = <String, double>{};
    raw.forEach((key, value) {
      final safeKey = '$key'.trim();
      if (safeKey.isEmpty) return;
      final parsed =
          value is num ? value.toDouble() : double.tryParse('$value');
      if (parsed == null || !parsed.isFinite) return;
      out[safeKey] = _normalizeFigureScale(parsed);
    });
    return out;
  }

  String _figureScaleKeyForAsset(Map<String, dynamic>? asset, int order) {
    final index = int.tryParse('${asset?['figure_index'] ?? ''}');
    if (index != null && index > 0) return 'idx:$index';
    final path = '${asset?['path'] ?? ''}'.trim();
    if (path.isNotEmpty) return 'path:$path';
    return 'ord:$order';
  }

  String _figurePairKey(String keyA, String keyB) {
    final a = keyA.trim();
    final b = keyB.trim();
    if (a.isEmpty || b.isEmpty || a == b) return '';
    return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
  }

  List<String> _figurePairParts(String pairKey) {
    final i = pairKey.indexOf('|');
    if (i <= 0 || i >= pairKey.length - 1) return const <String>[];
    final a = pairKey.substring(0, i).trim();
    final b = pairKey.substring(i + 1).trim();
    if (a.isEmpty || b.isEmpty || a == b) return const <String>[];
    return <String>[a, b];
  }

  Set<String> _figureHorizontalPairKeysOf(LearningProblemQuestion q) {
    final raw = q.meta['figure_horizontal_pairs'];
    if (raw is! List) return const <String>{};
    final out = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final map =
          Map<String, dynamic>.from(item.map((k, v) => MapEntry('$k', v)));
      final key = _figurePairKey(
        '${map['a'] ?? map['left'] ?? ''}',
        '${map['b'] ?? map['right'] ?? ''}',
      );
      if (key.isNotEmpty) out.add(key);
    }
    return out;
  }

  double _figureRenderScaleOf(LearningProblemQuestion q) {
    final raw = q.meta['figure_render_scale'];
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (parsed != null && parsed.isFinite) {
      return _normalizeFigureScale(parsed);
    }
    final map = _figureRenderScaleMapOf(q);
    if (map.isEmpty) return 1.0;
    final avg = map.values.fold<double>(0.0, (sum, v) => sum + v) / map.length;
    return _normalizeFigureScale(avg);
  }

  double _figureRenderScaleForAsset(
    LearningProblemQuestion q, {
    Map<String, dynamic>? asset,
    int order = 1,
  }) {
    final scaleMap = _figureRenderScaleMapOf(q);
    if (scaleMap.isEmpty) return _figureRenderScaleOf(q);
    final key = _figureScaleKeyForAsset(asset, order);
    final direct = scaleMap[key];
    if (direct != null) return direct;
    final index = int.tryParse('${asset?['figure_index'] ?? ''}');
    if (index != null) {
      final byIndex = scaleMap['idx:$index'];
      if (byIndex != null) return byIndex;
    }
    final path = '${asset?['path'] ?? ''}'.trim();
    if (path.isNotEmpty) {
      final byPath = scaleMap['path:$path'];
      if (byPath != null) return byPath;
    }
    return _figureRenderScaleOf(q);
  }

  String _figurePreviewUrlForPath(String path) {
    final safePath = path.trim();
    if (safePath.isEmpty) return '';
    return (figureUrlsByPath[safePath] ?? '').trim();
  }

  int _figureOrderHintInOrderedAssets(
    Map<String, dynamic>? asset,
    List<Map<String, dynamic>> orderedAssets,
  ) {
    if (asset == null || orderedAssets.isEmpty) return 1;
    final targetPath = '${asset['path'] ?? ''}'.trim();
    final targetId = '${asset['id'] ?? ''}'.trim();
    final targetIndex = int.tryParse('${asset['figure_index'] ?? ''}');
    for (var i = 0; i < orderedAssets.length; i += 1) {
      final candidate = orderedAssets[i];
      final candidatePath = '${candidate['path'] ?? ''}'.trim();
      if (targetPath.isNotEmpty && candidatePath == targetPath) return i + 1;
      final candidateId = '${candidate['id'] ?? ''}'.trim();
      if (targetId.isNotEmpty && candidateId == targetId) return i + 1;
      final candidateIndex = int.tryParse('${candidate['figure_index'] ?? ''}');
      if (targetIndex != null &&
          candidateIndex != null &&
          targetIndex == candidateIndex) {
        return i + 1;
      }
    }
    return 1;
  }

  Widget _buildInlineFigureVisual(
    LearningProblemQuestion q, {
    Map<String, dynamic>? asset,
    required int orderHint,
  }) {
    final assetPath = '${asset?['path'] ?? ''}'.trim();
    final previewUrl = _figurePreviewUrlForPath(assetPath);
    final hasFigureAsset = asset != null;
    final figureHeight = (expanded ? 232.0 : 138.0) *
        _figureRenderScaleForAsset(
          q,
          asset: asset,
          order: orderHint,
        );
    if (previewUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          previewUrl,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
          width: double.infinity,
          height: figureHeight,
          errorBuilder: (_, __, ___) => SizedBox(
            height: figureHeight * 0.62,
            child: const Center(
              child: Text(
                '그림 미리보기를 불러오지 못했습니다.',
                style: TextStyle(color: Color(0xFF906060), fontSize: 11.8),
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      alignment: Alignment.center,
      height: figureHeight * 0.62,
      decoration: BoxDecoration(
        color: const Color(0xFFFDFDFE),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFE5E8EF)),
      ),
      child: Text(
        hasFigureAsset ? '이미지 로딩 중...' : '그림 생성본 없음',
        style: const TextStyle(
          color: Color(0xFF6F7C95),
          fontSize: 11.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildInlineFigureInStem(
    LearningProblemQuestion q, {
    Map<String, dynamic>? asset,
  }) {
    final orderedAssets = _orderedFigureAssetsOf(q);
    final effectiveAsset = asset ?? _latestFigureAssetOf(q);
    final stemHead = _normalizePreviewLine(q.renderedStem)
        .replaceAll(_figureMarkerRegex, '')
        .trim();
    final hint = q.figureRefs
        .map(_normalizePreviewLine)
        .where((line) {
          if (line.isEmpty) return false;
          if (_figureMarkerRegex.hasMatch(line)) return false;
          final cleaned = line.replaceAll(_figureMarkerRegex, '').trim();
          if (cleaned.length < 4) return false;
          if (stemHead.contains(cleaned) || cleaned.contains(stemHead)) {
            return false;
          }
          return true;
        })
        .take(1)
        .toList(growable: false);
    final figureOrderHint =
        _figureOrderHintInOrderedAssets(effectiveAsset, orderedAssets);
    final currentKey = _figureScaleKeyForAsset(effectiveAsset, figureOrderHint);
    final pairKeys = _figureHorizontalPairKeysOf(q);
    final keyToAsset = <String, Map<String, dynamic>>{};
    final keyToOrder = <String, int>{};
    for (var i = 0; i < orderedAssets.length; i += 1) {
      final item = orderedAssets[i];
      final key = _figureScaleKeyForAsset(item, i + 1);
      keyToAsset[key] = item;
      keyToOrder[key] = i + 1;
    }
    String? partnerKey;
    for (final pairKey in pairKeys) {
      final parts = _figurePairParts(pairKey);
      if (parts.length != 2) continue;
      if (parts[0] == currentKey) {
        partnerKey = parts[1];
        break;
      }
      if (parts[1] == currentKey) {
        partnerKey = parts[0];
        break;
      }
    }
    if (partnerKey != null) {
      final partnerAsset = keyToAsset[partnerKey];
      final currentOrder = keyToOrder[currentKey] ?? figureOrderHint;
      final partnerOrder = keyToOrder[partnerKey] ?? (currentOrder + 1);
      if (partnerAsset != null) {
        if (partnerOrder < currentOrder) {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildInlineFigureVisual(
                      q,
                      asset: effectiveAsset,
                      orderHint: currentOrder,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildInlineFigureVisual(
                      q,
                      asset: partnerAsset,
                      orderHint: partnerOrder,
                    ),
                  ),
                ],
              ),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  hint.first,
                  maxLines: expanded ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF5A6680),
                    fontSize: 11.6,
                    height: 1.32,
                  ),
                ),
              ],
            ],
          ),
        );
      }
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInlineFigureVisual(
            q,
            asset: effectiveAsset,
            orderHint: figureOrderHint,
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              hint.first,
              maxLines: expanded ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5A6680),
                fontSize: 11.6,
                height: 1.32,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBoxedStemContainer({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        border: Border.all(color: const Color(0xFF3E3E3E), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildViewBlockContentLine(String line) {
    final normalized =
        _normalizePreviewLine(line.replaceAll(_structuralMarkerRegex, ' '));
    if (normalized.isEmpty || normalized == '<보기>') {
      return const SizedBox.shrink();
    }
    final itemMatch = RegExp(r'^([ㄱ-ㅎ①②③④⑤⑥⑦⑧⑨⑩]|\d{1,2})\s*[\.\)]\s*(.+)$')
        .firstMatch(normalized);
    final lineHeight = _denseMathLineHeight(normalized, normal: 1.76);
    final style = TextStyle(
      color: const Color(0xFF2D2D2D),
      fontSize: expanded ? 13.8 : 13.2,
      height: lineHeight,
      fontFamily: _previewKoreanFontFamily,
    );
    if (itemMatch == null) {
      final verticalPad =
          _mathSymmetricVerticalPadding(normalized, compact: true);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPad),
        child: LatexTextRenderer(
          _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
          softWrap: true,
          enableDisplayMath: true,
          inlineMathScale: _previewMathScale,
          fractionInlineMathScale: _previewFractionMathScale,
          displayMathScale: _previewMathScale,
          blockVerticalPadding: lineHeight >= 1.9 ? 1.2 : 0.7,
          style: style,
        ),
      );
    }
    final rawLabel = (itemMatch.group(1) ?? '').trim();
    final content = (itemMatch.group(2) ?? '').trim();
    final labelText =
        RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]$').hasMatch(rawLabel) ? rawLabel : '$rawLabel.';
    final contentVerticalPad =
        _mathSymmetricVerticalPadding(content, compact: true);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: contentVerticalPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: expanded ? 24 : 22,
            child: Text(
              labelText,
              style: style.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: LatexTextRenderer(
              _toPreviewMathMarkup(content, forceMathTokenWrap: true),
              softWrap: true,
              enableDisplayMath: true,
              inlineMathScale: _previewMathScale,
              fractionInlineMathScale: _previewFractionMathScale,
              displayMathScale: _previewMathScale,
              blockVerticalPadding:
                  _denseMathLineHeight(content, normal: 1.76) >= 1.9
                      ? 1.2
                      : 0.7,
              style: TextStyle(
                color: style.color,
                fontSize: style.fontSize,
                height: _denseMathLineHeight(content, normal: 1.76),
                fontFamily: _previewKoreanFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewBlockPanel(List<String> lines) {
    final items =
        lines.where((line) => line.trim().isNotEmpty).toList(growable: false);
    final contentLines =
        items.where((line) => line != '<보기>').toList(growable: false);
    const borderColor = Color(0xFF3F3F3F);
    const panelBgColor = Color(0xFFFCFCFC);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in contentLines) ...[
                  _buildViewBlockContentLine(line),
                  if (line != contentLines.last)
                    SizedBox(height: expanded ? 12 : 10),
                ],
              ],
            ),
          ),
          Positioned(
            top: -11,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                color: panelBgColor,
                padding: EdgeInsets.zero,
                child: const Text(
                  '<보기>',
                  style: TextStyle(
                    color: Color(0xFF232323),
                    fontSize: 13.6,
                    fontWeight: FontWeight.w400,
                    fontFamily: _previewKoreanFontFamily,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStemTextPreviewLine(
    String text, {
    double fontSize = 13.4,
    double normalHeight = 1.66,
  }) {
    final normalized = _normalizePreviewMultiline(
        text.replaceAll(_structuralMarkerRegex, ' '));
    final lineHeight = _denseMathLineHeight(normalized, normal: normalHeight);
    final verticalPad = _mathSymmetricVerticalPadding(normalized);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad),
      child: LatexTextRenderer(
        _toPreviewMathMarkup(normalized, forceMathTokenWrap: true),
        softWrap: true,
        enableDisplayMath: true,
        inlineMathScale: _previewMathScale,
        fractionInlineMathScale: _previewFractionMathScale,
        displayMathScale: _previewMathScale,
        blockVerticalPadding: lineHeight >= 1.82 ? 1.8 : 1.0,
        style: TextStyle(
          fontSize: fontSize,
          height: lineHeight,
          color: const Color(0xFF232323),
          fontFamily: _previewKoreanFontFamily,
        ),
      ),
    );
  }

  List<Widget> _buildStemPreviewBlocks(
    LearningProblemQuestion q,
    String stemPreview,
  ) {
    final out = <Widget>[];
    final normalized = _normalizePreviewMultiline(stemPreview);
    if (normalized.isEmpty) return out;
    final assets = _orderedFigureAssetsOf(q);

    if (_boxMarkerStartRegex.hasMatch(normalized)) {
      return _buildStemBlocksFromMarkers(q, normalized, assets);
    }

    final boxedGroups = _boxedStemGroups(stemPreview);
    if (boxedGroups.isNotEmpty) {
      final firstGroup = boxedGroups.first;
      final firstJoined = firstGroup.join('\n');
      final beforeText = normalized.split(firstGroup.first).first.trim();
      if (beforeText.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(beforeText));
      }
      final boxChildren = <Widget>[];
      int boxedAssetCursor = 0;
      for (final line in firstGroup) {
        final figMatches =
            _figureMarkerRegex.allMatches(line).toList(growable: false);
        if (figMatches.isEmpty) {
          if (boxChildren.isNotEmpty) {
            boxChildren.add(const SizedBox(height: 4));
          }
          boxChildren.add(_buildStemTextPreviewLine(
            line,
            fontSize: expanded ? 13.5 : 13.1,
            normalHeight: 1.74,
          ));
        } else {
          int lCursor = 0;
          for (final fm in figMatches) {
            final beforeFig = line
                .substring(lCursor, fm.start)
                .replaceAll(_figureMarkerRegex, '')
                .trim();
            if (beforeFig.isNotEmpty) {
              if (boxChildren.isNotEmpty) {
                boxChildren.add(const SizedBox(height: 4));
              }
              boxChildren.add(_buildStemTextPreviewLine(
                beforeFig,
                fontSize: expanded ? 13.5 : 13.1,
                normalHeight: 1.74,
              ));
            }
            if (boxedAssetCursor < assets.length) {
              boxChildren.add(_buildInlineFigureInStem(
                q,
                asset: assets[boxedAssetCursor],
              ));
              boxedAssetCursor += 1;
            }
            lCursor = fm.end;
          }
          final afterFig =
              line.substring(lCursor).replaceAll(_figureMarkerRegex, '').trim();
          if (afterFig.isNotEmpty) {
            if (boxChildren.isNotEmpty) {
              boxChildren.add(const SizedBox(height: 4));
            }
            boxChildren.add(_buildStemTextPreviewLine(
              afterFig,
              fontSize: expanded ? 13.5 : 13.1,
              normalHeight: 1.74,
            ));
          }
        }
      }
      if (boxChildren.isNotEmpty) {
        out.add(_buildBoxedStemContainer(children: boxChildren));
      }
      final afterSource = stemPreview.replaceFirst(firstJoined, '').trim();
      final afterText = _normalizePreviewMultiline(afterSource);
      if (afterText.isNotEmpty) {
        final afterFigureMatches =
            _figureMarkerRegex.allMatches(afterText).toList(growable: false);
        if (afterFigureMatches.isEmpty) {
          out.add(_buildStemTextPreviewLine(afterText));
        } else {
          int afterCursor = 0;
          for (final match in afterFigureMatches) {
            final beforeFig = _normalizePreviewLine(
                afterText.substring(afterCursor, match.start));
            if (beforeFig.isNotEmpty) {
              out.add(_buildStemTextPreviewLine(beforeFig));
            }
            if (boxedAssetCursor < assets.length) {
              out.add(_buildInlineFigureInStem(
                q,
                asset: assets[boxedAssetCursor],
              ));
              boxedAssetCursor += 1;
            }
            afterCursor = match.end;
          }
          final afterTail =
              _normalizePreviewLine(afterText.substring(afterCursor));
          if (afterTail.isNotEmpty) {
            out.add(_buildStemTextPreviewLine(afterTail));
          }
        }
      }
      while (boxedAssetCursor < assets.length) {
        out.add(_buildInlineFigureInStem(
          q,
          asset: assets[boxedAssetCursor],
        ));
        boxedAssetCursor += 1;
      }
      if (assets.isEmpty && q.figureRefs.isNotEmpty) {
        out.add(_buildInlineFigureInStem(q));
      }
      return out;
    }

    return _buildStemBlocksPlain(q, normalized, assets);
  }

  List<Widget> _buildStemBlocksFromMarkers(
    LearningProblemQuestion q,
    String normalized,
    List<Map<String, dynamic>> assets,
  ) {
    final out = <Widget>[];
    int assetCursor = 0;

    final cleaned = normalized
        .replaceAll(_paragraphMarkerRegex, '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();

    final parts = cleaned.split(_boxMarkerStartRegex);
    for (int pi = 0; pi < parts.length; pi += 1) {
      final part = parts[pi];
      if (part.isEmpty) continue;

      final endSplit = part.split(_boxMarkerEndRegex);
      if (endSplit.length >= 2) {
        final boxContent = endSplit[0].trim();
        if (boxContent.isNotEmpty) {
          final boxChildren = <Widget>[];
          final boxLines = boxContent
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList(growable: false);
          for (final line in boxLines) {
            final figMatches =
                _figureMarkerRegex.allMatches(line).toList(growable: false);
            if (figMatches.isEmpty) {
              if (boxChildren.isNotEmpty) {
                boxChildren.add(const SizedBox(height: 4));
              }
              boxChildren.add(_buildStemTextPreviewLine(
                line,
                fontSize: expanded ? 13.5 : 13.1,
                normalHeight: 1.74,
              ));
            } else {
              int lCursor = 0;
              for (final fm in figMatches) {
                final beforeFig = line
                    .substring(lCursor, fm.start)
                    .replaceAll(_figureMarkerRegex, '')
                    .trim();
                if (beforeFig.isNotEmpty) {
                  if (boxChildren.isNotEmpty) {
                    boxChildren.add(const SizedBox(height: 4));
                  }
                  boxChildren.add(_buildStemTextPreviewLine(
                    beforeFig,
                    fontSize: expanded ? 13.5 : 13.1,
                    normalHeight: 1.74,
                  ));
                }
                if (assetCursor < assets.length) {
                  boxChildren.add(_buildInlineFigureInStem(
                    q,
                    asset: assets[assetCursor],
                  ));
                  assetCursor += 1;
                }
                lCursor = fm.end;
              }
              final afterFig = line
                  .substring(lCursor)
                  .replaceAll(_figureMarkerRegex, '')
                  .trim();
              if (afterFig.isNotEmpty) {
                if (boxChildren.isNotEmpty) {
                  boxChildren.add(const SizedBox(height: 4));
                }
                boxChildren.add(_buildStemTextPreviewLine(
                  afterFig,
                  fontSize: expanded ? 13.5 : 13.1,
                  normalHeight: 1.74,
                ));
              }
            }
          }
          if (boxChildren.isNotEmpty) {
            out.add(_buildBoxedStemContainer(children: boxChildren));
          }
        }
        final afterBox = endSplit.sublist(1).join('').trim();
        if (afterBox.isNotEmpty) {
          assetCursor =
              _appendPlainStemSegment(q, afterBox, assets, assetCursor, out);
        }
      } else {
        final text = part.trim();
        if (text.isNotEmpty) {
          assetCursor =
              _appendPlainStemSegment(q, text, assets, assetCursor, out);
        }
      }
    }

    while (assetCursor < assets.length) {
      out.add(_buildInlineFigureInStem(
        q,
        asset: assets[assetCursor],
      ));
      assetCursor += 1;
    }
    if (assets.isEmpty && q.figureRefs.isNotEmpty) {
      out.add(_buildInlineFigureInStem(q));
    }
    return out;
  }

  List<Widget> _buildStemBlocksPlain(
    LearningProblemQuestion q,
    String normalized,
    List<Map<String, dynamic>> assets,
  ) {
    final out = <Widget>[];
    final cleaned = normalized
        .replaceAll(_paragraphMarkerRegex, '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
    final matches =
        _figureMarkerRegex.allMatches(cleaned).toList(growable: false);
    if (matches.isEmpty) {
      out.add(_buildStemTextPreviewLine(cleaned));
      if (assets.isNotEmpty) {
        final maxFallback = expanded ? assets.length : 1;
        for (int i = 0; i < maxFallback && i < assets.length; i += 1) {
          out.add(_buildInlineFigureInStem(
            q,
            asset: assets[i],
          ));
        }
      } else if (q.figureRefs.isNotEmpty) {
        out.add(_buildInlineFigureInStem(q));
      }
      return out;
    }
    int cursor = 0;
    int assetCursor = 0;
    for (final match in matches) {
      final before =
          _normalizePreviewMultiline(cleaned.substring(cursor, match.start));
      if (before.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(before));
      }
      if (assetCursor < assets.length) {
        out.add(_buildInlineFigureInStem(
          q,
          asset: assets[assetCursor],
        ));
        assetCursor += 1;
      } else {
        out.add(_buildInlineFigureInStem(q));
      }
      cursor = match.end;
    }
    final tail = _normalizePreviewMultiline(cleaned.substring(cursor));
    if (tail.isNotEmpty) {
      out.add(_buildStemTextPreviewLine(tail));
    }
    while (assetCursor < assets.length) {
      out.add(_buildInlineFigureInStem(
        q,
        asset: assets[assetCursor],
      ));
      assetCursor += 1;
    }
    if (assets.isEmpty && q.figureRefs.isNotEmpty) {
      out.add(_buildInlineFigureInStem(q));
    }
    return out;
  }

  int _appendPlainStemSegment(
    LearningProblemQuestion q,
    String text,
    List<Map<String, dynamic>> assets,
    int assetCursor,
    List<Widget> out,
  ) {
    final figMatches =
        _figureMarkerRegex.allMatches(text).toList(growable: false);
    if (figMatches.isEmpty) {
      out.add(_buildStemTextPreviewLine(text));
      return assetCursor;
    }
    int cursor = 0;
    for (final match in figMatches) {
      final before = _normalizePreviewLine(text.substring(cursor, match.start));
      if (before.isNotEmpty) {
        out.add(_buildStemTextPreviewLine(before));
      }
      if (assetCursor < assets.length) {
        out.add(_buildInlineFigureInStem(
          q,
          asset: assets[assetCursor],
        ));
        assetCursor += 1;
      }
      cursor = match.end;
    }
    final tail = _normalizePreviewLine(text.substring(cursor));
    if (tail.isNotEmpty) {
      out.add(_buildStemTextPreviewLine(tail));
    }
    return assetCursor;
  }

  Widget _buildChoicePreviewLine(
      LearningProblemQuestion q, LearningProblemChoice c) {
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final lineHeight = _choicePreviewLineHeight(rendered);
    final symmetricPad = _mathSymmetricVerticalPadding(rendered);
    final previewText = _toPreviewMathMarkup(
      rendered,
      forceMathTokenWrap: true,
      compactFractions: true,
    );
    const contentFontSize = 13.4;
    const labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
      fontFamily: _previewKoreanFontFamily,
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: symmetricPad + 1.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: const TextStyle(
              color: Color(0xFF232323),
              fontSize: labelFontSize,
              fontWeight: FontWeight.w500,
              fontFamily: _previewKoreanFontFamily,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: LatexTextRenderer(
              previewText,
              softWrap: true,
              enableDisplayMath: true,
              inlineMathScale: _previewMathScale,
              fractionInlineMathScale: _previewFractionMathScale,
              displayMathScale: _previewMathScale,
              blockVerticalPadding: lineHeight >= 1.80
                  ? 1.6
                  : lineHeight >= 1.70
                      ? 1.2
                      : 0.8,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }

  int _estimateVisualLength(String text) {
    var s = text;
    s = s.replaceAllMapped(
      RegExp(r'\\(?:d?frac)\{([^{}]*)\}\{([^{}]*)\}'),
      (m) => '${m.group(1)}/${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'\{([^{}]*)\}\s*\\over\s*\{([^{}]*)\}'),
      (m) => '${m.group(1)}/${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'\\mathrm\{([^{}]*)\}'),
      (m) => m.group(1) ?? '',
    );
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ');
    s = s.replaceAll(RegExp(r'[{}]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length;
  }

  double _estimateChoiceRequiredWidth(
      LearningProblemQuestion q, LearningProblemChoice choice) {
    final text = _normalizePreviewLine(q.renderChoiceText(choice));
    final visual = _estimateVisualLength(text);
    final latex = _sanitizeLatexForMathTex(text);
    final hasNestedFraction = _containsNestedFractionExpression(latex);
    final hasFraction = _containsFractionExpression(latex);
    final hasLongMath =
        RegExp(r'\\(sqrt|sum|int|overline|lim|log)').hasMatch(latex);
    final symbolCount = RegExp(r'[=+\-×÷<>^_]').allMatches(text).length;

    var width = 30.0 + visual * 7.4 + symbolCount * 2.6;
    if (hasFraction) width += 24.0;
    if (hasNestedFraction) width += 46.0;
    if (hasLongMath) width += 34.0;
    return width;
  }

  String _choiceLayoutMode(
    LearningProblemQuestion q,
    List<LearningProblemChoice> choices,
    double availableWidth,
  ) {
    if (choices.length != 5) return 'stacked';
    final safeWidth = availableWidth.isFinite && availableWidth > 120
        ? availableWidth
        : 620.0;
    const singleGaps = 8.0 * 4;
    const splitGaps = 8.0 * 2;
    final singleCellWidth = (safeWidth - singleGaps) / 5;
    final splitCellWidth = (safeWidth - splitGaps) / 3;
    final requiredWidths = choices
        .map((choice) => _estimateChoiceRequiredWidth(q, choice))
        .toList(growable: false);

    final fitsSingle = requiredWidths.every((w) => w <= singleCellWidth);
    if (fitsSingle) return 'single';

    final topFits = requiredWidths.take(3).every((w) => w <= splitCellWidth);
    final bottomFits = requiredWidths.skip(3).every((w) => w <= splitCellWidth);
    if (topFits && bottomFits) return 'split_3_2';
    return 'stacked';
  }

  Widget _buildChoiceInlineCell(
    LearningProblemQuestion q,
    LearningProblemChoice c,
  ) {
    final rendered = _normalizePreviewLine(q.renderChoiceText(c));
    final lineHeight = _choicePreviewLineHeight(rendered);
    final symmetricPad = _mathSymmetricVerticalPadding(rendered, compact: true);
    final contentFontSize = expanded ? 13.6 : 13.4;
    final labelFontSize = contentFontSize + 1.6;
    final textStyle = TextStyle(
      color: const Color(0xFF232323),
      fontSize: contentFontSize,
      height: lineHeight,
      fontFamily: _previewKoreanFontFamily,
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: symmetricPad),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: TextStyle(
              color: const Color(0xFF232323),
              fontSize: labelFontSize,
              fontWeight: FontWeight.w500,
              fontFamily: _previewKoreanFontFamily,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: LatexTextRenderer(
              _toPreviewMathMarkup(
                rendered,
                forceMathTokenWrap: true,
                compactFractions: true,
              ),
              softWrap: true,
              enableDisplayMath: true,
              inlineMathScale: _previewMathScale,
              fractionInlineMathScale: _previewFractionMathScale,
              displayMathScale: _previewMathScale,
              blockVerticalPadding: lineHeight >= 1.80
                  ? 1.2
                  : lineHeight >= 1.70
                      ? 0.9
                      : 0.5,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceHorizontalRow(
    LearningProblemQuestion q,
    List<LearningProblemChoice> rowChoices, {
    required int columns,
  }) {
    final cells = <Widget>[];
    for (int i = 0; i < columns; i += 1) {
      if (i < rowChoices.length) {
        cells.add(
          Expanded(
            child: _buildChoiceInlineCell(
              q,
              rowChoices[i],
            ),
          ),
        );
      } else {
        cells.add(const Expanded(child: SizedBox.shrink()));
      }
      if (i < columns - 1) {
        cells.add(SizedBox(width: expanded ? 10 : 8));
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cells,
    );
  }

  List<Widget> _buildChoicePreviewBlocks(
    LearningProblemQuestion q, {
    List<LearningProblemChoice>? sourceChoices,
    double availableWidth = 620,
  }) {
    final choices = (sourceChoices ?? _previewChoicesOf(q))
        .take(expanded ? 10 : 5)
        .toList(growable: false);
    if (choices.isEmpty) return const <Widget>[];
    final mode = _choiceLayoutMode(q, choices, availableWidth);
    if (mode == 'single') {
      return <Widget>[
        _buildChoiceHorizontalRow(q, choices, columns: 5),
      ];
    }
    if (mode == 'split_3_2') {
      return <Widget>[
        _buildChoiceHorizontalRow(
          q,
          choices.take(3).toList(growable: false),
          columns: 3,
        ),
        SizedBox(height: expanded ? 7 : 6),
        _buildChoiceHorizontalRow(
          q,
          choices.skip(3).toList(growable: false),
          columns: 3,
        ),
      ];
    }
    return <Widget>[
      for (final choice in choices) _buildChoicePreviewLine(q, choice),
    ];
  }

  String _stemPreviewWithMarkers(LearningProblemQuestion q) {
    var out = _normalizePreviewMultiline(q.renderedStem);
    if (out.isEmpty) return '';
    out = out.replaceFirst(RegExp(r'^(\s*\[(문단|박스끝)\]\s*)+'), '');
    out = out.replaceFirst(RegExp(r'(\s*\[(문단|박스시작)\]\s*)+$'), '');
    final qn = q.questionNumber.trim();
    if (qn.isNotEmpty) {
      final lines = out.split('\n');
      if (lines.isNotEmpty) {
        lines[0] = _stripLeadingQuestionNumberToken(lines[0], qn);
        out = lines
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join('\n');
      }
    }
    final markerNormalized = out.replaceAll(RegExp(r'<\s*보\s*기>'), '<보기>');
    final lastMarker = markerNormalized.lastIndexOf('<보기>');
    if (lastMarker > 0 &&
        RegExp(r'[ㄱ-ㅎ]\.').hasMatch(markerNormalized.substring(lastMarker))) {
      return _normalizePreviewMultiline(
          markerNormalized.substring(0, lastMarker));
    }
    return _normalizePreviewMultiline(out);
  }

  String _stripLeadingQuestionNumberToken(String line, String questionNumber) {
    if (line.trim().isEmpty) return line;
    final escaped = RegExp.escape(questionNumber.trim());
    if (escaped.isEmpty) return line;
    return line
        .replaceFirst(
          RegExp('^\\s*$escaped\\s*번\\s*(?:[\\.)．])?\\s*'),
          '',
        )
        .replaceFirst(
          RegExp('^\\s*$escaped\\s*[\\.)．]\\s*'),
          '',
        )
        .replaceFirst(
          RegExp('^\\s*$escaped\\s+(?=[^\\s])'),
          '',
        );
  }

  double _stemToChoiceGap() {
    const stemLineHeight = 1.66;
    final stemFontSize = expanded ? 13.8 : 13.4;
    final stemLineSpacing = stemFontSize * (stemLineHeight - 1.0);
    return stemLineSpacing * 2;
  }

  Widget _buildPdfQuestionNumberLabel(LearningProblemQuestion q) {
    final number =
        q.questionNumber.trim().isEmpty ? '?' : q.questionNumber.trim();
    return Text(
      '$number.',
      style: TextStyle(
        color: const Color(0xFF232323),
        fontSize: (expanded ? 13.8 : 13.4) + 1.0,
        fontWeight: FontWeight.w600,
        height: 1.58,
        fontFamily: _previewKoreanFontFamily,
      ),
    );
  }

  Widget _buildPdfPreviewPaperContent(LearningProblemQuestion q) {
    final stemPreview = _stemPreviewWithMarkers(q);
    final viewBlockLines = _viewBlockPreviewLines(q, max: expanded ? 18 : 6);
    final stemBlocks = _buildStemPreviewBlocks(q, stemPreview);
    final previewChoices = _previewChoicesOf(q);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final numberingInset = showQuestionNumberPrefix
            ? (_pdfQuestionNumberLaneWidth + _pdfQuestionNumberGap)
            : 0.0;
        final choiceAvailableWidth =
            math.max(120.0, constraints.maxWidth - numberingInset);
        final contentChildren = <Widget>[
          ...stemBlocks,
          if (viewBlockLines.isNotEmpty) ...[
            _buildViewBlockPanel(
              viewBlockLines.take(expanded ? 18 : 6).toList(growable: false),
            ),
          ],
          if (previewChoices.isNotEmpty) ...[
            SizedBox(height: _stemToChoiceGap()),
            ..._buildChoicePreviewBlocks(
              q,
              sourceChoices: previewChoices,
              availableWidth: choiceAvailableWidth,
            ),
          ],
        ];
        Widget questionContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: contentChildren,
        );
        if (showQuestionNumberPrefix) {
          questionContent = Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(left: numberingInset),
                child: questionContent,
              ),
              Positioned(
                left: 0,
                top: _pdfQuestionNumberTopOffset,
                width: _pdfQuestionNumberLaneWidth,
                child: Align(
                  alignment: Alignment.topRight,
                  child: _buildPdfQuestionNumberLabel(q),
                ),
              ),
            ],
          );
        }
        return DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFF232323),
            fontSize: 13.4,
            height: 1.46,
            fontFamily: _previewKoreanFontFamily,
          ),
          child: questionContent,
        );
      },
    );
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(bordered ? 6 : 0),
        border: bordered
            ? Border.all(color: const Color(0xFFD5D5D5))
            : Border.all(color: Colors.transparent),
        boxShadow: shadow
            ? const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      padding: contentPadding,
      child: scrollable
          ? SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: body,
            )
          : body,
    );
  }
}
