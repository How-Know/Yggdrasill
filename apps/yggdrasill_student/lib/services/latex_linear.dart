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
  // 집합·논리 — 중학 집합 단원 답에서 그대로 쓰인다.
  'cup': '∪',
  'cap': '∩',
  'in': '∈',
  'notin': '∉',
  'ni': '∋',
  'subset': '⊂',
  'supset': '⊃',
  'subseteq': '⊆',
  'supseteq': '⊇',
  'nsubseteq': '⊈',
  'nsupseteq': '⊉',
  'emptyset': '∅',
  'varnothing': '∅',
  'complement': '∁',
  'setminus': r'\',
  'forall': '∀',
  'exists': '∃',
  'nexists': '∄',
  'land': '∧',
  'wedge': '∧',
  'lor': '∨',
  'vee': '∨',
  'lnot': '¬',
  'neg': '¬',
  'therefore': '∴',
  'because': '∵',
  // 조건제시법 구분자 — `{x | x>0}`.
  'mid': '|',
  'vert': '|',
};

/// `\mathbb{R}` 같은 수 체계 기호.
const Map<String, String> _blackboardBold = <String, String>{
  'N': 'ℕ',
  'Z': 'ℤ',
  'Q': 'ℚ',
  'R': 'ℝ',
  'C': 'ℂ',
};

/// 여는 구분자 → 닫는 구분자. `\left\{ ... \right.` 처럼 한쪽만 쓰인
/// 표기를 균형 잡힌 선형 표기로 되돌릴 때 쓴다.
const Map<String, String> _fenceClosers = <String, String>{
  '(': ')',
  '[': ']',
  '{': '}',
  '|': '|',
  '⌊': '⌋',
  '⌈': '⌉',
};

/// 행/열 구조를 갖는 LaTeX 환경 — MyScript 가 세로로 나열된 필기를
/// 이 형태로 내보낸다 (연립방정식, 세로로 쓴 집합 원소).
const Set<String> _matrixEnvironments = <String>{
  'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'Bmatrix',
  'array', 'aligned', 'align', 'split', 'gathered',
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
  '∪': r'\cup ',
  '∩': r'\cap ',
  '∈': r'\in ',
  '∉': r'\notin ',
  '∋': r'\ni ',
  '⊂': r'\subset ',
  '⊃': r'\supset ',
  '⊆': r'\subseteq ',
  '⊇': r'\supseteq ',
  '⊈': r'\nsubseteq ',
  '⊉': r'\nsupseteq ',
  '∅': r'\varnothing ',
  '∁': r'\complement ',
  '∀': r'\forall ',
  '∃': r'\exists ',
  '∄': r'\nexists ',
  '∧': r'\land ',
  '∨': r'\lor ',
  '¬': r'\lnot ',
  '∴': r'\therefore ',
  '∵': r'\because ',
  'ℕ': r'\mathbb{N}',
  'ℤ': r'\mathbb{Z}',
  'ℚ': r'\mathbb{Q}',
  'ℝ': r'\mathbb{R}',
  'ℂ': r'\mathbb{C}',
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

  /// 열려 있는 `\left` 구분자 스택. `\right.`(닫는 쪽 없음)를 만나면
  /// 여기서 짝을 찾아 닫아 준다.
  final List<String> _openFences = <String>[];

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
        final open = _readDelimiter();
        _openFences.add(open);
        return open == '.' ? '' : open;
      case 'right':
        final close = _readDelimiter();
        final open = _openFences.isEmpty ? null : _openFences.removeLast();
        if (close != '.') return close;
        // `\left\{ ... \right.` — 연립·세로 나열 표기. 균형을 맞춰 닫는다.
        return open == null ? '' : (_fenceClosers[open] ?? '');
      case 'begin':
        return _environment(_readArgument().trim());
      case 'end':
        // 짝이 맞지 않는 \end — 환경 이름만 소비하고 버린다.
        _readArgument();
        return '';
      case 'mathbb':
      case 'mathbf':
      case 'mathcal':
        final body = _readArgument().trim();
        return _blackboardBold[body] ?? _convert(body);
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

  /// `\left` / `\right` 뒤의 구분자 한 글자를 읽는다.
  /// `\left\{` 처럼 이스케이프된 형태도 처리한다. 없으면 '.'(구분자 없음).
  String _readDelimiter() {
    if (_done) return '.';
    final ch = source[_pos];
    _pos += 1;
    if (ch != r'\') return ch;
    if (_done) return '.';
    final escaped = source[_pos];
    _pos += 1;
    // \left\lbrace 같은 이름 형태도 받아 준다.
    if (_isLetter(escaped)) {
      final start = _pos - 1;
      while (!_done && _isLetter(source[_pos])) {
        _pos += 1;
      }
      switch (source.substring(start, _pos)) {
        case 'lbrace':
          return '{';
        case 'rbrace':
          return '}';
        case 'lbrack':
          return '[';
        case 'rbrack':
          return ']';
        case 'vert':
        case 'mid':
          return '|';
        default:
          return '.';
      }
    }
    return escaped;
  }

  /// 행렬 계열 환경(`cases`, `matrix`, `array` …)을 선형 표기로 편다.
  ///
  /// MyScript 는 세로로 나열된 필기를 이 형태로 내보낸다. 학생이 집합
  /// 원소를 세로로 썼든 연립방정식을 썼든 구조는 같으므로, 행을 쉼표로
  /// 이어 붙여 원문을 최대한 보존한다. `cases` 는 왼쪽 중괄호가 표기에
  /// 포함되므로 중괄호로 감싼다.
  String _environment(String name) {
    if (!_matrixEnvironments.contains(name)) {
      // 모르는 환경 — 이름은 버리고 본문만 살린다.
      return _convert(_readEnvironmentBody(name));
    }
    // array/tabular 의 열 정렬 인자(`{l}`)는 내용이 아니므로 버린다.
    if ((name == 'array' || name == 'tabular') && !_done && source[_pos] == '{') {
      _readGroup();
    }
    final body = _readEnvironmentBody(name);
    final rows = <List<String>>[];
    for (final row in _splitRows(body)) {
      final cells = <String>[];
      for (final cell in _splitCells(row)) {
        final converted = _convert(cell);
        if (converted.isNotEmpty) cells.add(converted);
      }
      if (cells.isNotEmpty) rows.add(cells);
    }

    if (rows.isEmpty) return name == 'cases' ? '{}' : '';
    // 한 열짜리(대부분의 경우)는 행을 쉼표로 잇고, 실제 행렬은 행을
    // 세미콜론으로 구분해 구조를 남긴다.
    final singleColumn = rows.every((row) => row.length == 1);
    final joined = singleColumn
        ? rows.map((row) => row.first).join(',')
        : rows.map((row) => row.join(',')).join(';');
    return name == 'cases' ? '{$joined}' : joined;
  }

  /// `\end{name}` 까지의 본문을 읽는다 (중첩 환경 고려).
  String _readEnvironmentBody(String name) {
    final beginToken = '\\begin{$name}';
    final endToken = '\\end{$name}';
    final start = _pos;
    var depth = 1;
    var i = _pos;
    while (i < source.length) {
      if (source.startsWith(beginToken, i)) {
        depth += 1;
        i += beginToken.length;
        continue;
      }
      if (source.startsWith(endToken, i)) {
        depth -= 1;
        if (depth == 0) {
          final body = source.substring(start, i);
          _pos = i + endToken.length;
          return body;
        }
        i += endToken.length;
        continue;
      }
      i += 1;
    }
    // 짝이 없는 경우 — 남은 전부를 본문으로 본다.
    _pos = source.length;
    return source.substring(start);
  }

  /// 환경 본문을 `\\`(행 구분) 기준으로 자른다. 중첩 환경·그룹 안의
  /// `\\` 는 건너뛴다.
  static List<String> _splitRows(String body) =>
      _splitTopLevel(body, isSeparator: (s, i) {
        return s[i] == r'\' && i + 1 < s.length && s[i + 1] == r'\';
      }, separatorLength: 2);

  /// 한 행을 `&`(열 구분) 기준으로 자른다.
  static List<String> _splitCells(String row) =>
      _splitTopLevel(row, isSeparator: (s, i) => s[i] == '&', separatorLength: 1);

  static List<String> _splitTopLevel(
    String source, {
    required bool Function(String, int) isSeparator,
    required int separatorLength,
  }) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    var envDepth = 0;
    var i = 0;
    while (i < source.length) {
      if (source.startsWith(r'\begin{', i)) {
        envDepth += 1;
      } else if (source.startsWith(r'\end{', i)) {
        envDepth -= 1;
      }
      final ch = source[i];
      if (ch == '{') depth += 1;
      if (ch == '}') depth -= 1;
      if (depth == 0 && envDepth <= 0 && isSeparator(source, i)) {
        parts.add(buffer.toString());
        buffer.clear();
        i += separatorLength;
        continue;
      }
      buffer.write(ch);
      i += 1;
    }
    parts.add(buffer.toString());
    return parts;
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
