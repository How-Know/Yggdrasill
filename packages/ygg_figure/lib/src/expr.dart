import 'dart:math' as math;

/// 그림 파일 안의 수식("2a+1", "sqrt(x)+1", "A.x" 등)을 읽고 계산한다.
///
/// - 곱하기 기호는 생략할 수 있다: `2x`, `3sin(x)`, `2(x+1)`.
/// - 삼각함수는 라디안. 상수 `pi`, `e`.
/// - `A.x`, `A.y` 는 이미 정해진 점의 좌표.
typedef Lookup = double? Function(String name);

class ExprError implements Exception {
  ExprError(this.message);
  final String message;
  @override
  String toString() => '수식 오류: $message';
}

class Expr {
  Expr._(this.source, this._node);

  final String source;
  final _Node _node;

  static final _cache = <String, Expr>{};

  static Expr parse(String source) => _cache[source] ??= Expr._(source, _Parser(source).parse());

  double eval(Lookup lookup) => _node(lookup);
}

typedef _Node = double Function(Lookup lookup);

const _functions1 = <String, double Function(double)>{
  'sin': math.sin,
  'cos': math.cos,
  'tan': math.tan,
  'asin': math.asin,
  'acos': math.acos,
  'atan': math.atan,
  'sqrt': math.sqrt,
  'exp': math.exp,
  'ln': math.log,
  'abs': _abs,
  'floor': _floor,
  'ceil': _ceil,
  'sign': _sign,
  'cbrt': _cbrt,
  'log2': _log2,
  'log10': _log10,
  'rad': _rad,
  'deg': _deg,
  'sinh': _sinh,
  'cosh': _cosh,
};

double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;
double _cosh(double v) => (math.exp(v) + math.exp(-v)) / 2;

double _abs(double v) => v.abs();
double _floor(double v) => v.floorToDouble();
double _ceil(double v) => v.ceilToDouble();
double _sign(double v) => v.sign;
double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
double _log2(double v) => math.log(v) / math.ln2;
double _log10(double v) => math.log(v) / math.ln10;
double _rad(double v) => v * math.pi / 180;
double _deg(double v) => v * 180 / math.pi;

const _functionsN = {'log', 'min', 'max', 'pow', 'atan2'};

class _Parser {
  _Parser(this.src);
  final String src;
  int pos = 0;

  _Node parse() {
    final node = _sum();
    _skip();
    if (pos < src.length) throw ExprError('"$src" 의 ${pos + 1}번째 글자를 읽을 수 없습니다');
    return node;
  }

  void _skip() {
    while (pos < src.length && src.codeUnitAt(pos) <= 32) {
      pos++;
    }
  }

  bool _eat(String ch) {
    _skip();
    if (pos < src.length && src[pos] == ch) {
      pos++;
      return true;
    }
    return false;
  }

  String? _peek() {
    _skip();
    return pos < src.length ? src[pos] : null;
  }

  _Node _sum() {
    var left = _product();
    while (true) {
      if (_eat('+')) {
        final l = left, r = _product();
        left = (s) => l(s) + r(s);
      } else if (_eat('-')) {
        final l = left, r = _product();
        left = (s) => l(s) - r(s);
      } else {
        return left;
      }
    }
  }

  _Node _product() {
    var left = _unary();
    while (true) {
      if (_eat('*')) {
        final l = left, r = _unary();
        left = (s) => l(s) * r(s);
      } else if (_eat('/')) {
        final l = left, r = _unary();
        left = (s) => l(s) / r(s);
      } else {
        final c = _peek();
        // 곱하기 생략: 숫자·괄호 뒤에 이름이나 괄호가 오면 곱으로 본다.
        if (c != null && (c == '(' || _isNameStart(c))) {
          final l = left, r = _power();
          left = (s) => l(s) * r(s);
        } else {
          return left;
        }
      }
    }
  }

  _Node _unary() {
    if (_eat('-')) {
      final v = _unary();
      return (s) => -v(s);
    }
    if (_eat('+')) return _unary();
    return _power();
  }

  _Node _power() {
    final base = _primary();
    if (_eat('^')) {
      final exp = _unary();
      return (s) {
        final b = base(s), e = exp(s);
        // 음수의 홀수 분의 일 제곱(세제곱근 등)은 실수 값으로 낸다.
        if (b < 0 && e != e.roundToDouble()) {
          final inv = 1 / e;
          if ((inv - inv.roundToDouble()).abs() < 1e-9 && inv.round().isOdd) {
            return -math.pow(-b, e).toDouble();
          }
        }
        return math.pow(b, e).toDouble();
      };
    }
    return base;
  }

  _Node _primary() {
    _skip();
    if (pos >= src.length) throw ExprError('"$src" 가 중간에 끝났습니다');
    final c = src[pos];
    if (c == '(') {
      pos++;
      final v = _sum();
      if (!_eat(')')) throw ExprError('"$src" 에 닫는 괄호가 없습니다');
      return v;
    }
    if (_isDigit(c) || c == '.') {
      final start = pos;
      while (pos < src.length && (_isDigit(src[pos]) || src[pos] == '.')) {
        pos++;
      }
      final value = double.parse(src.substring(start, pos));
      return (_) => value;
    }
    if (_isNameStart(c)) {
      final start = pos;
      while (pos < src.length && (_isNameStart(src[pos]) || _isDigit(src[pos]))) {
        pos++;
      }
      if (pos < src.length && src[pos] == "'") pos++;
      if (pos + 1 < src.length && src[pos] == '.' && 'xyz'.contains(src[pos + 1])) pos += 2;
      final name = src.substring(start, pos);
      if (_functions1.containsKey(name) || _functionsN.contains(name)) {
        if (!_eat('(')) throw ExprError('"$src": $name 뒤에 괄호가 필요합니다');
        final args = <_Node>[_sum()];
        while (_eat(',')) {
          args.add(_sum());
        }
        if (!_eat(')')) throw ExprError('"$src" 에 닫는 괄호가 없습니다');
        return _call(name, args);
      }
      if (name == 'pi') return (_) => math.pi;
      return (s) {
        final v = s(name);
        if (v != null) return v;
        if (name == 'e') return math.e;
        throw ExprError('"$name" 의 값을 모릅니다');
      };
    }
    throw ExprError('"$src" 의 ${pos + 1}번째 글자를 읽을 수 없습니다');
  }

  _Node _call(String name, List<_Node> args) {
    final f1 = _functions1[name];
    if (f1 != null) {
      if (args.length != 1) throw ExprError('$name 은 값 하나를 받습니다');
      final a = args[0];
      return (s) => f1(a(s));
    }
    switch (name) {
      case 'log':
        // log(x) 는 상용로그, log(b, x) 는 밑이 b 인 로그.
        if (args.length == 1) {
          final a = args[0];
          return (s) => math.log(a(s)) / math.ln10;
        }
        final b = args[0], x = args[1];
        return (s) => math.log(x(s)) / math.log(b(s));
      case 'pow':
        final b = args[0], x = args[1];
        return (s) => math.pow(b(s), x(s)).toDouble();
      case 'atan2':
        final y = args[0], x = args[1];
        return (s) => math.atan2(y(s), x(s));
      case 'min':
        return (s) => args.map((a) => a(s)).reduce(math.min);
      default:
        return (s) => args.map((a) => a(s)).reduce(math.max);
    }
  }

  static bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;
  static bool _isNameStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95;
  }
}
