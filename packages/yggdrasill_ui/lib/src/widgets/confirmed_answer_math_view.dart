import 'package:flutter/material.dart';

import 'latex_text_renderer.dart';

/// 학습앱 정답 다이얼로그(`GradingConfirmedAnswerDialog`)와 학생앱 셀프 채점 다이얼로그가
/// 함께 쓰는 로컬 정답 조판 포매터·렌더러.
class ConfirmedAnswerMathFormatter {
  ConfirmedAnswerMathFormatter._();

  static final RegExp _envBlockRe =
      RegExp(r'\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}');
  static final RegExp _multiSpaceRe = RegExp(r'\s+');
  static final RegExp _commaRe = RegExp(r',');
  static final RegExp _semicolonRe = RegExp(r';');
  static final RegExp _equalsRe = RegExp(r'=');
  static final RegExp _ltOpRe = RegExp(r'<');
  static final RegExp _gtOpRe = RegExp(r'>');
  static final RegExp _timesRe = RegExp(r'(?<![A-Za-z])\\times(?![A-Za-z])');
  static final RegExp _divRe = RegExp(r'(?<![A-Za-z])\\div(?![A-Za-z])');
  static final RegExp _cdotRe = RegExp(r'(?<![A-Za-z])\\cdot(?![A-Za-z])');
  static final RegExp _pmRe = RegExp(r'(?<![A-Za-z])\\pm(?![A-Za-z])');
  static final RegExp _leRe = RegExp(r'(?<![A-Za-z])\\le(?![A-Za-z])');
  static final RegExp _geRe = RegExp(r'(?<![A-Za-z])\\ge(?![A-Za-z])');
  static final RegExp _ltCmdRe = RegExp(r'(?<![A-Za-z])\\lt(?![A-Za-z])');
  static final RegExp _gtCmdRe = RegExp(r'(?<![A-Za-z])\\gt(?![A-Za-z])');
  static final RegExp _neRe = RegExp(r'(?<![A-Za-z])\\ne(?![A-Za-z])');
  static final RegExp _closeParenTightRe = RegExp(r'\)(?=[A-Za-z0-9\\])');
  static final RegExp _nonKoreanRe = RegExp(r'[^가-힣]+');
  static final RegExp _hasKoreanRe = RegExp(r'[가-힣]');
  static final RegExp _fracCmdRe = RegExp(r'\\(?:dfrac|tfrac|frac)\s*(?=\{)');
  static final RegExp _slashFracRe = RegExp(
    r'(?<![\\\w])(-?\d+(?:\.\d+)?)\s*/\s*(-?\d+(?:\.\d+)?)(?![\w])',
  );
  static final RegExp _mathCandidateRe = RegExp(
    r'[A-Za-z0-9=<>^_{}\\]|\\times|\\over|\\le|\\ge|\\lt|\\gt|\\frac|\\dfrac',
  );
  static final RegExp _operatorTokenRe = RegExp(
    r'^(?:=|,|;|:|[+\-*/<>]|\\times|\\div|\\cdot|\\pm|\\le|\\ge|\\lt|\\gt|\\ne)+$',
  );
  static const List<String> _setPartKoreanKeys = <String>[
    '가',
    '나',
    '다',
    '라',
    '마',
    '바',
    '사',
    '아',
    '자',
    '차',
    '카',
    '타',
  ];
  static final RegExp _setParenNumMarkerRe = RegExp(r'^[(（]\s*(\d{1,2})\s*[)）]');
  static final RegExp _setBareNumMarkerRe = RegExp(r'^(\d{1,2})\s*[)）]');
  static final RegExp _setKorMarkerRe = RegExp(r'^[(（]\s*([가-힣])\s*[)）]');
  static final RegExp _whitespaceCharRe = RegExp(r'\s');

  /// 학습앱 정답 다이얼로그와 동일한 표시 원문 선택 규칙.
  static String selectDisplayAnswer({
    required String answerKind,
    String? answerText,
    String? answerLatex2d,
  }) {
    final kind = answerKind.trim().toLowerCase();
    final text = (answerText ?? '').trim();
    final latex2d = (answerLatex2d ?? '').trim();
    if (kind == 'subjective' && latex2d.isNotEmpty) {
      return latex2d;
    }
    if (text.isNotEmpty) {
      return text;
    }
    if (latex2d.isNotEmpty) {
      return latex2d;
    }
    return '-';
  }

  /// 우측 정답리스트·정답 다이얼로그와 동일한 토큰 단위 줄바꿈 + 2D 환경(`$$...$$`) 보존.
  static List<String> normalizeAnswerLinesForDisplay(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '-') return const <String>['-'];

    if (_envBlockRe.hasMatch(trimmed)) {
      final out = <String>[];
      var last = 0;
      for (final m in _envBlockRe.allMatches(trimmed)) {
        if (m.start > last) {
          final before = trimmed.substring(last, m.start).trim();
          if (before.isNotEmpty) {
            for (final line in before.split('\n')) {
              final mk = _overflowAnswerMarkup(line.trim());
              if (mk.isNotEmpty) out.add(mk);
            }
          }
        }
        out.add('\$\$${m.group(0)!.trim()}\$\$');
        last = m.end;
      }
      if (last < trimmed.length) {
        final after = trimmed.substring(last).trim();
        if (after.isNotEmpty) {
          for (final line in after.split('\n')) {
            final mk = _overflowAnswerMarkup(line.trim());
            if (mk.isNotEmpty) out.add(mk);
          }
        }
      }
      return out.isEmpty ? const <String>['-'] : out;
    }

    if (trimmed.contains('\n')) {
      final lines = trimmed
          .split('\n')
          .map((line) => _overflowAnswerMarkup(line.trim()))
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      return lines.isEmpty ? const <String>['-'] : lines;
    }
    final single = _overflowAnswerMarkup(trimmed);
    return <String>[single.isEmpty ? '-' : single];
  }

  /// 하위 문항 라벨 분리: `(1) ... (2) ...` / `1) ... 2) ...` / `(가) ... (나) ...`.
  static List<({String label, String value})> splitSetAnswerParts(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    final parts = <({String label, String value})>[];
    var i = 0;
    var expected = 1;
    var contentStart = -1;
    var mode = 0;
    var parenDepth = 0;
    var braceDepth = 0;

    String labelOf(int n) {
      if (mode == 2) return '(${_setPartKoreanKeys[n - 1]})';
      if (mode == 1) return '$n)';
      return '($n)';
    }

    while (i < text.length) {
      final prev = i == 0 ? ' ' : text[i - 1];
      if (parenDepth == 0 &&
          braceDepth == 0 &&
          _whitespaceCharRe.hasMatch(prev)) {
        final head = text.substring(i);
        var markerLen = 0;
        if (expected == 1) {
          if (text.substring(0, i).trim().isEmpty) {
            final mp = _setParenNumMarkerRe.firstMatch(head);
            if (mp != null && int.parse(mp.group(1)!) == 1) {
              markerLen = mp.group(0)!.length;
              mode = 0;
            } else {
              final mb = _setBareNumMarkerRe.firstMatch(head);
              if (mb != null && int.parse(mb.group(1)!) == 1) {
                markerLen = mb.group(0)!.length;
                mode = 1;
              } else {
                final mk = _setKorMarkerRe.firstMatch(head);
                if (mk != null && mk.group(1) == _setPartKoreanKeys[0]) {
                  markerLen = mk.group(0)!.length;
                  mode = 2;
                }
              }
            }
          }
        } else if (mode == 0) {
          final mp = _setParenNumMarkerRe.firstMatch(head);
          if (mp != null && int.parse(mp.group(1)!) == expected) {
            markerLen = mp.group(0)!.length;
          }
        } else if (mode == 1) {
          final mb = _setBareNumMarkerRe.firstMatch(head);
          if (mb != null && int.parse(mb.group(1)!) == expected) {
            markerLen = mb.group(0)!.length;
          }
        } else {
          final mk = _setKorMarkerRe.firstMatch(head);
          if (mk != null &&
              expected <= _setPartKoreanKeys.length &&
              mk.group(1) == _setPartKoreanKeys[expected - 1]) {
            markerLen = mk.group(0)!.length;
          }
        }

        if (markerLen > 0) {
          if (expected == 1) {
            contentStart = i + markerLen;
            expected = 2;
            i += markerLen;
            continue;
          }
          final value = text.substring(contentStart, i).trim();
          if (value.isNotEmpty) {
            parts.add((label: labelOf(expected - 1), value: value));
            contentStart = i + markerLen;
            expected += 1;
            i += markerLen;
            continue;
          }
        }
      }

      final ch = text[i];
      if (ch == '(' || ch == '（') {
        parenDepth += 1;
      } else if (ch == ')' || ch == '）') {
        if (parenDepth > 0) parenDepth -= 1;
      } else if (ch == '{') {
        braceDepth += 1;
      } else if (ch == '}') {
        if (braceDepth > 0) braceDepth -= 1;
      }
      i += 1;
    }

    if (expected < 3 || contentStart < 0) return const [];
    final last = text.substring(contentStart).trim();
    if (last.isEmpty) return const [];
    parts.add((label: labelOf(expected - 1), value: last));
    if (parts.length > 12) return const [];
    return parts;
  }

  static String _preprocessOverflowRaw(String raw) {
    var s = raw
        .replaceAll('\r', ' ')
        .replaceAll(r'\(', ' ')
        .replaceAll(r'\)', ' ')
        .replaceAll(r'$$', ' ')
        .replaceAll(r'$', ' ')
        .replaceAll(r'\quad', ' ')
        .replaceAll(r'\qquad', ' ')
        .replaceAll(r'\ ', ' ');
    const opMap = <String, String>{
      '×': r' \times ',
      '÷': r' \div ',
      '·': r' \cdot ',
      '≤': r' \le ',
      '≥': r' \ge ',
      '≠': r' \ne ',
      '±': r' \pm ',
      '＜': ' < ',
      '＞': ' > ',
      '〈': ' < ',
      '〉': ' > ',
      '⟨': ' < ',
      '⟩': ' > ',
      '《': ' < ',
      '》': ' > ',
      r'\bigcirc': '○',
    };
    for (final e in opMap.entries) {
      s = s.replaceAll(e.key, e.value);
    }
    return s.replaceAll(_multiSpaceRe, ' ').trim();
  }

  static String _insertSplittableSpaces(String input) {
    var s = input;
    s = s.replaceAllMapped(_commaRe, (_) => ' , ');
    s = s.replaceAllMapped(_semicolonRe, (_) => ' ; ');
    s = s.replaceAllMapped(_equalsRe, (_) => ' = ');
    s = s.replaceAllMapped(_ltOpRe, (_) => ' < ');
    s = s.replaceAllMapped(_gtOpRe, (_) => ' > ');
    s = s.replaceAllMapped(_timesRe, (_) => r' \times ');
    s = s.replaceAllMapped(_divRe, (_) => r' \div ');
    s = s.replaceAllMapped(_cdotRe, (_) => r' \cdot ');
    s = s.replaceAllMapped(_pmRe, (_) => r' \pm ');
    s = s.replaceAllMapped(_leRe, (_) => r' \le ');
    s = s.replaceAllMapped(_geRe, (_) => r' \ge ');
    s = s.replaceAllMapped(_ltCmdRe, (_) => r' \lt ');
    s = s.replaceAllMapped(_gtCmdRe, (_) => r' \gt ');
    s = s.replaceAllMapped(_neRe, (_) => r' \ne ');
    s = s.replaceAllMapped(_closeParenTightRe, (_) => ') ');
    return s.replaceAll(_multiSpaceRe, ' ').trim();
  }

  static List<String> _splitTopLevelTokens(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    var braceDepth = 0;
    for (var i = 0; i < s.length; i += 1) {
      final c = s[i];
      if (c == '{') braceDepth += 1;
      if (c == '}') braceDepth = braceDepth > 0 ? braceDepth - 1 : 0;
      if (c == ' ' && braceDepth == 0) {
        final token = buf.toString();
        if (token.isNotEmpty) out.add(token);
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    final tail = buf.toString();
    if (tail.isNotEmpty) out.add(tail);
    return out;
  }

  static String _overflowAnswerMarkup(String raw) {
    final preprocessed = _preprocessOverflowRaw(raw);
    if (preprocessed.isEmpty) return '';
    final buffer = StringBuffer();
    var lastIndex = 0;
    for (final match in _nonKoreanRe.allMatches(preprocessed)) {
      if (match.start > lastIndex) {
        buffer.write(preprocessed.substring(lastIndex, match.start));
      }
      final segment = preprocessed.substring(match.start, match.end);
      final core = segment.trim();
      final leading = segment.startsWith(' ') ? ' ' : '';
      final trailing = segment.endsWith(' ') && segment.length > 1 ? ' ' : '';
      if (core.isEmpty) {
        buffer.write(segment);
        lastIndex = match.end;
        continue;
      }
      buffer.write(leading);
      buffer.write(_buildMathSegmentMarkup(core));
      buffer.write(trailing);
      lastIndex = match.end;
    }
    if (lastIndex < preprocessed.length) {
      buffer.write(preprocessed.substring(lastIndex));
    }
    return buffer.toString();
  }

  static String _promoteFractionsForOverflow(String latex) {
    var out = latex;
    out = out.replaceAllMapped(_fracCmdRe, (_) => r'\dfrac');
    out = out.replaceAllMapped(
      _slashFracRe,
      (m) => '\\dfrac{${m.group(1) ?? ''}}{${m.group(2) ?? ''}}',
    );
    return out;
  }

  static bool _looksLikeMathCandidate(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return false;
    if (_hasKoreanRe.hasMatch(input)) return false;
    return _mathCandidateRe.hasMatch(input);
  }

  static String _buildMathSegmentMarkup(String segment) {
    if (!segment.contains(',') &&
        !segment.contains(';') &&
        segment.length <= 28) {
      final latex = _promoteFractionsForOverflow(segment);
      if (_looksLikeMathCandidate(latex)) {
        final hasFraction = latex.contains(r'\frac') ||
            latex.contains(r'\dfrac') ||
            latex.contains(r'\tfrac');
        return hasFraction ? '\\(\\displaystyle $latex\\)' : '\\($latex\\)';
      }
      return latex;
    }
    return _buildTokenizedMathMarkup(segment);
  }

  static String _buildTokenizedMathMarkup(String segment) {
    final spaced = _insertSplittableSpaces(segment);
    final tokens = _splitTopLevelTokens(spaced);
    if (tokens.isEmpty) return '';
    final pieces = <String>[];
    for (final rawToken in tokens) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final latex = _promoteFractionsForOverflow(token);
      final isOperatorToken = _operatorTokenRe.hasMatch(token);
      if (isOperatorToken || _looksLikeMathCandidate(token)) {
        final hasFraction = latex.contains(r'\frac') ||
            latex.contains(r'\dfrac') ||
            latex.contains(r'\tfrac');
        pieces.add(
          hasFraction ? '\\(\\displaystyle $latex\\)' : '\\($latex\\)',
        );
      } else {
        pieces.add(latex);
      }
    }
    return pieces.join(' ');
  }
}

/// 정규화된 정답 마크업 줄 목록을 학습앱 정답 다이얼로그와 동일한 스타일로 그린다.
class ConfirmedAnswerMathLinesView extends StatelessWidget {
  const ConfirmedAnswerMathLinesView({
    super.key,
    required this.lines,
    required this.textColor,
    this.fontSize = 24,
  });

  final List<String> lines;
  final Color textColor;
  final double fontSize;

  Widget _buildSingleLine(String normalizedMarkup) {
    return LatexTextRenderer(
      normalizedMarkup,
      dollarMath: false,
      softWrap: true,
      enableDisplayMath: true,
      displayMathOverflow: DisplayMathOverflow.scaleDown,
      overflow: TextOverflow.visible,
      style: TextStyle(
        color: textColor,
        fontFamily: LatexTextRenderer.v2TextFontFamily,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return _buildSingleLine('-');
    }
    if (lines.length == 1) {
      return _buildSingleLine(lines.first);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i += 1) ...[
          if (i > 0) const SizedBox(height: 8),
          _buildSingleLine(lines[i]),
        ],
      ],
    );
  }
}

/// 단일 정답 문자열(세트 소문항 `(1) ... (2) ...` 포함)을 로컬 렌더러로 그린다.
class ConfirmedAnswerMathView extends StatelessWidget {
  const ConfirmedAnswerMathView({
    super.key,
    required this.displayAnswer,
    this.textColor = const Color(0xFF17201F),
    this.subTextColor = const Color(0xFF5C6665),
    this.fontSize = 24,
    this.partLabelFontSize = 15,
  });

  final String displayAnswer;
  final Color textColor;
  final Color subTextColor;
  final double fontSize;
  final double partLabelFontSize;

  @override
  Widget build(BuildContext context) {
    final rawParts =
        ConfirmedAnswerMathFormatter.splitSetAnswerParts(displayAnswer);
    if (rawParts.length >= 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rawParts.length; i += 1) ...[
            if (i > 0) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 38,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      rawParts[i].label,
                      style: TextStyle(
                        color: subTextColor,
                        fontFamily: LatexTextRenderer.v2TextFontFamily,
                        fontSize: partLabelFontSize,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ConfirmedAnswerMathLinesView(
                    lines: ConfirmedAnswerMathFormatter
                        .normalizeAnswerLinesForDisplay(rawParts[i].value),
                    textColor: textColor,
                    fontSize: fontSize,
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }

    return ConfirmedAnswerMathLinesView(
      lines: ConfirmedAnswerMathFormatter.normalizeAnswerLinesForDisplay(
        displayAnswer,
      ),
      textColor: textColor,
      fontSize: fontSize,
    );
  }
}
