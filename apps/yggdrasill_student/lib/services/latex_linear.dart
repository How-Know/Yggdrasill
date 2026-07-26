/// LaTeX → 앱 선형 표기 변환.
///
/// MyScript iink Math Recognizer 는 결과를 LaTeX 로 내보낸다.
/// 앱의 정답 입력·채점 파이프라인은 선형 표기를 쓰므로
/// (VLM 폴백과 동일 규칙: `3x^2+2x-1`, `(2)/(3)`, `2√(3)`, `x=3`)
/// 여기서 최소한의 구조 변환을 한다. 지원하지 않는 명령은 이름만 벗겨
/// 원문을 최대한 보존한다.
library;

const Map<String, String> _commandSymbols = <String, String>{
  'times': '*',
  'cdot': '*',
  'div': '/',
  'pm': '±',
  'mp': '∓',
  'le': '≤',
  'leq': '≤',
  'ge': '≥',
  'geq': '≥',
  'ne': '≠',
  'neq': '≠',
  'infty': '∞',
  'pi': 'π',
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'theta': 'θ',
  'lambda': 'λ',
  'mu': 'μ',
  'sigma': 'σ',
  'omega': 'ω',
  'circ': '°',
  'degree': '°',
  'percent': '%',
  'sim': '~',
  'approx': '≈',
};

/// LaTeX 문자열을 앱 선형 표기로 변환한다. 빈 입력은 빈 문자열.
String latexToLinear(String latex) {
  final source = latex.trim();
  if (source.isEmpty) return '';
  final parser = _LatexParser(source);
  final out = parser.parse();
  // 공백 제거 — 선형 표기는 공백 없이 쓴다.
  return out.replaceAll(RegExp(r'\s+'), '');
}

const Map<String, String> _linearSymbols = <String, String>{
  '±': r'\pm ',
  '∓': r'\mp ',
  '≤': r'\le ',
  '≥': r'\ge ',
  '≠': r'\ne ',
  '∞': r'\infty ',
  'π': r'\pi ',
  'α': r'\alpha ',
  'β': r'\beta ',
  'γ': r'\gamma ',
  'δ': r'\delta ',
  'θ': r'\theta ',
  'λ': r'\lambda ',
  'μ': r'\mu ',
  'σ': r'\sigma ',
  'ω': r'\omega ',
  '°': r'{}^\circ ',
  '≈': r'\approx ',
  '×': r'\times ',
  '·': r'\cdot ',
  '÷': r'\div ',
  '%': r'\% ',
};

/// 앱 선형 표기를 LaTeX 로 역변환한다 — 2D 조판 표시용.
///
/// 지원 패턴 (수식 편집기 직렬화 + [latexToLinear] 출력):
/// `(a)/(b)` 분수, `√(x)`·`√[n](x)` 루트, `x^(n)`·`x^2` 지수,
/// 순환소수(문자+U+0307), 그리스·비교 기호. 한글 등 비수식 문자는
/// `\text{}` 로 감싼다. 변환 실패분은 원문을 보존한다.
String linearToLatex(String linear) {
  final source = linear.trim();
  if (source.isEmpty) return '';
  return _LinearParser(source).parse();
}

class _LinearParser {
  _LinearParser(this.source);

  final String source;
  int _pos = 0;

  bool get _done => _pos >= source.length;

  String parse() {
    final out = StringBuffer();
    final text = StringBuffer(); // 연속된 비수식(한글 등) 문자 버퍼

    void flushText() {
      if (text.isEmpty) return;
      out.write('\\text{$text}');
      text.clear();
    }

    while (!_done) {
      final ch = source[_pos];

      if (ch == '(') {
        flushText();
        final group = _readParenGroup();
        // `(a)/(b)` → 분수
        if (!_done &&
            source[_pos] == '/' &&
            _pos + 1 < source.length &&
            source[_pos + 1] == '(') {
          _pos += 1; // skip '/'
          final den = _readParenGroup();
          out.write(
              '\\frac{${_convert(group)}}{${_convert(den)}}');
        } else {
          out.write('\\left(${_convert(group)}\\right)');
        }
        continue;
      }

      if (ch == '√') {
        flushText();
        _pos += 1;
        String? index;
        if (!_done && source[_pos] == '[') {
          index = _readBracketGroup();
        }
        String body;
        if (!_done && source[_pos] == '(') {
          body = _readParenGroup();
        } else {
          body = _done ? '' : source[_pos];
          if (!_done) _pos += 1;
        }
        out.write(index == null || index.isEmpty
            ? '\\sqrt{${_convert(body)}}'
            : '\\sqrt[${_convert(index)}]{${_convert(body)}}');
        continue;
      }

      if (ch == '^' || ch == '_') {
        flushText();
        _pos += 1;
        String script;
        if (!_done && source[_pos] == '(') {
          script = _readParenGroup();
        } else {
          script = _done ? '' : source[_pos];
          if (!_done) _pos += 1;
        }
        out.write('$ch{${_convert(script)}}');
        continue;
      }

      // 순환소수 — 직전 문자를 \dot{} 로 감싼다.
      if (ch == '\u0307') {
        _pos += 1;
        if (text.isNotEmpty) {
          final buffered = text.toString();
          text.clear();
          final last = buffered.substring(buffered.length - 1);
          final rest = buffered.substring(0, buffered.length - 1);
          if (rest.isNotEmpty) out.write('\\text{$rest}');
          out.write('\\dot{$last}');
        } else {
          final built = out.toString();
          if (built.isNotEmpty) {
            final last = built.substring(built.length - 1);
            out
              ..clear()
              ..write(built.substring(0, built.length - 1))
              ..write('\\dot{$last}');
          }
        }
        continue;
      }

      final symbol = _linearSymbols[ch];
      if (symbol != null) {
        flushText();
        out.write(symbol);
        _pos += 1;
        continue;
      }

      if (_isMathChar(ch)) {
        flushText();
        // { } 는 LaTeX 예약 문자 — 이스케이프.
        out.write(ch == '{' || ch == '}' ? '\\$ch' : ch);
        _pos += 1;
        continue;
      }

      // 한글 등 비수식 문자 — \text{} 버퍼에 쌓는다.
      text.write(ch);
      _pos += 1;
    }
    flushText();
    return out.toString();
  }

  /// 괄호 균형을 맞춰 `( ... )` 내용을 돌려준다 (괄호 제외).
  String _readParenGroup() {
    assert(source[_pos] == '(');
    var depth = 0;
    final start = _pos + 1;
    var i = _pos;
    while (i < source.length) {
      if (source[i] == '(') depth += 1;
      if (source[i] == ')') {
        depth -= 1;
        if (depth == 0) break;
      }
      i += 1;
    }
    final content = source.substring(start, i.clamp(start, source.length));
    _pos = (i + 1).clamp(0, source.length);
    return content;
  }

  String _readBracketGroup() {
    assert(source[_pos] == '[');
    final start = _pos + 1;
    var i = start;
    while (i < source.length && source[i] != ']') {
      i += 1;
    }
    final content = source.substring(start, i);
    _pos = (i + 1).clamp(0, source.length);
    return content;
  }

  static String _convert(String fragment) => _LinearParser(fragment).parse();

  static bool _isMathChar(String ch) {
    final code = ch.codeUnitAt(0);
    // ASCII 인쇄 문자 전부 수식으로 취급 (숫자·영문·연산자·구두점).
    return code >= 0x20 && code <= 0x7E;
  }
}

class _LatexParser {
  _LatexParser(this.source);

  final String source;
  int _pos = 0;

  bool get _done => _pos >= source.length;

  String parse() {
    final buffer = StringBuffer();
    while (!_done) {
      buffer.write(_next());
    }
    return buffer.toString();
  }

  /// 다음 토큰 하나를 선형 표기로 변환한다.
  String _next() {
    final ch = source[_pos];
    if (ch == r'\') return _command();
    if (ch == '{') {
      // 명령 밖의 그룹은 내용만 남긴다 (예: {x+1} → x+1).
      return _convert(_readGroup());
    }
    if (ch == '}') {
      _pos += 1;
      return '';
    }
    if (ch == '^' || ch == '_') {
      _pos += 1;
      final script = _readArgument();
      final converted = _convert(script);
      if (converted.isEmpty) return '';
      // 한 글자면 괄호 생략 (x^2), 여러 글자면 괄호 (x^(2x+1)).
      return converted.length == 1 ? '$ch$converted' : '$ch($converted)';
    }
    _pos += 1;
    return ch;
  }

  /// `\` 로 시작하는 명령 처리.
  String _command() {
    _pos += 1; // skip backslash
    if (_done) return '';

    // \\, \{, \%, \  같은 단일 문자 이스케이프.
    final first = source[_pos];
    if (!_isLetter(first)) {
      _pos += 1;
      if (first == '{' || first == '}') return first;
      if (first == '%') return '%';
      if (first == ',' || first == ';' || first == '!' || first == ' ') {
        return '';
      }
      return first;
    }

    final start = _pos;
    while (!_done && _isLetter(source[_pos])) {
      _pos += 1;
    }
    final name = source.substring(start, _pos);

    switch (name) {
      case 'frac':
      case 'dfrac':
      case 'tfrac':
        final numerator = _convert(_readArgument());
        final denominator = _convert(_readArgument());
        return '($numerator)/($denominator)';
      case 'sqrt':
        final index = _readOptionalArgument();
        final radicand = _convert(_readArgument());
        if (index != null && index.trim().isNotEmpty) {
          // n제곱근 — 수식 편집기와 동일한 n√() 표기.
          return '${_convert(index)}√($radicand)';
        }
        return '√($radicand)';
      case 'left':
      case 'right':
        // \left( \right) — 뒤따르는 구분자는 그대로 살린다.
        if (!_done) {
          final delim = source[_pos];
          _pos += 1;
          if (delim == r'\') {
            // \left\{ 같은 형태 — 이스케이프 문자 하나 더 소비.
            if (!_done) {
              final escaped = source[_pos];
              _pos += 1;
              return escaped == '.' ? '' : escaped;
            }
            return '';
          }
          return delim == '.' ? '' : delim;
        }
        return '';
      case 'text':
      case 'mathrm':
      case 'operatorname':
        return _convert(_readArgument());
      case 'overline':
        // 순환소수 표기 — 내용만 보존한다.
        return _convert(_readArgument());
      default:
        final symbol = _commandSymbols[name];
        if (symbol != null) return symbol;
        // 모르는 명령: 이름을 그대로 남긴다 (sin, cos, log 등).
        return name;
    }
  }

  /// `{...}` 또는 단일 문자 인자를 읽는다 (원문 그대로).
  String _readArgument() {
    if (_done) return '';
    if (source[_pos] == '{') return _readGroup();
    if (source[_pos] == r'\') {
      // \frac\pi2 같은 형태 — 명령 하나가 인자.
      final start = _pos;
      _pos += 1;
      while (!_done && _isLetter(source[_pos])) {
        _pos += 1;
      }
      return source.substring(start, _pos);
    }
    final ch = source[_pos];
    _pos += 1;
    return ch;
  }

  /// `[...]` 선택 인자 (\sqrt[3]{x}). 없으면 null.
  String? _readOptionalArgument() {
    if (_done || source[_pos] != '[') return null;
    final start = _pos + 1;
    var depth = 1;
    var i = start;
    while (i < source.length && depth > 0) {
      if (source[i] == '[') depth += 1;
      if (source[i] == ']') depth -= 1;
      i += 1;
    }
    final content = source.substring(start, i - 1);
    _pos = i;
    return content;
  }

  /// 중괄호 그룹을 읽어 내용(중괄호 제외)을 돌려준다.
  String _readGroup() {
    assert(source[_pos] == '{');
    var depth = 0;
    final start = _pos + 1;
    var i = _pos;
    while (i < source.length) {
      if (source[i] == '{') depth += 1;
      if (source[i] == '}') {
        depth -= 1;
        if (depth == 0) break;
      }
      i += 1;
    }
    final content = source.substring(start, i.clamp(start, source.length));
    _pos = (i + 1).clamp(0, source.length);
    return content;
  }

  static String _convert(String fragment) =>
      _LatexParser(fragment).parse().trim();

  static bool _isLetter(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  }
}
