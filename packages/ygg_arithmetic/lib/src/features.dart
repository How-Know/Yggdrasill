import 'dart:math' as math;

const featureSchemaVersion = 1;
const extractorVersion = 'natural_v1';
const maxOperandDigits = 40;

enum ArithmeticOp { add, sub, mul, div }

enum ParseStatus { ok, empty, unsupported, divZero, tooLong }

class ParsedExpression {
  const ParsedExpression({
    required this.status,
    required this.display,
    this.left,
    this.right,
    this.op,
    this.message = '',
  });

  final ParseStatus status;
  final String display;
  final BigInt? left;
  final BigInt? right;
  final ArithmeticOp? op;
  final String message;

  bool get ok => status == ParseStatus.ok;
}

class NaturalFeatures {
  const NaturalFeatures({
    required this.display,
    required this.op,
    required this.left,
    required this.right,
    required this.leftDigits,
    required this.rightDigits,
    required this.resultDigits,
    required this.fingerprint,
    required this.containsZeroOperand,
    required this.containsOneOperand,
    required this.equalOperands,
    required this.powerOfTenOperand,
    required this.multipleOfTenOperand,
    required this.aLessThanB,
    required this.carryCount,
    required this.carryChainLength,
    required this.leadingCarry,
    required this.borrowCount,
    required this.borrowChainLength,
    required this.zeroCrossingCount,
    required this.digitMultiplicationCount,
    required this.nontrivialDigitMultiplicationCount,
    required this.partialProductCount,
    required this.nonzeroPartialProductCount,
    required this.multiplicationCarryCount,
    required this.partialSumCarryCount,
    required this.zeroMultiplierDigitCount,
    required this.quotient,
    required this.remainder,
    required this.quotientDigits,
    required this.internalQuotientZeroCount,
    required this.trailingQuotientZeroCount,
    required this.divisionStepCount,
    required this.bringDownCount,
    required this.nonzeroQuotientDigitCount,
  });

  final String display;
  final ArithmeticOp op;
  final BigInt left;
  final BigInt right;
  final int leftDigits;
  final int rightDigits;
  final int? resultDigits;
  final String fingerprint;
  final bool containsZeroOperand;
  final bool containsOneOperand;
  final bool equalOperands;
  final bool powerOfTenOperand;
  final bool multipleOfTenOperand;
  final bool aLessThanB;
  final int? carryCount;
  final int? carryChainLength;
  final bool? leadingCarry;
  final int? borrowCount;
  final int? borrowChainLength;
  final int? zeroCrossingCount;
  final int? digitMultiplicationCount;
  final int? nontrivialDigitMultiplicationCount;
  final int? partialProductCount;
  final int? nonzeroPartialProductCount;
  final int? multiplicationCarryCount;
  final int? partialSumCarryCount;
  final int? zeroMultiplierDigitCount;
  final BigInt? quotient;
  final BigInt? remainder;
  final int? quotientDigits;
  final int? internalQuotientZeroCount;
  final int? trailingQuotientZeroCount;
  final int? divisionStepCount;
  final int? bringDownCount;
  final int? nonzeroQuotientDigitCount;

  bool get hasRemainder => remainder != null && remainder! > BigInt.zero;
  bool get dividendLessThanDivisor => op == ArithmeticOp.div && left < right;
  bool get divisorIsOne => op == ArithmeticOp.div && right == BigInt.one;
}

ParsedExpression parseNaturalExpression(String raw) {
  var text = raw.trim();
  if (text.isEmpty) {
    return const ParsedExpression(status: ParseStatus.empty, display: '', message: '식이 비어 있습니다.');
  }
  text = text.replaceAll(' ', '').replaceAll(',', '');
  final eq = text.indexOf('=');
  if (eq >= 0) text = text.substring(0, eq);
  text = text.replaceAll('−', '-').replaceAll('–', '-').replaceAll('—', '-');
  text = text.replaceAll('×', '*').replaceAll('x', '*').replaceAll('X', '*').replaceAll('÷', '/');
  if (text.isEmpty) {
    return ParsedExpression(status: ParseStatus.empty, display: raw.trim(), message: '식이 비어 있습니다.');
  }
  final match = RegExp(r'^(\d+)([+\-*/])(\d+)$').firstMatch(text);
  if (match == null) {
    return ParsedExpression(
      status: ParseStatus.unsupported,
      display: raw.trim(),
      message: '자연수 두 개와 사칙연산 하나만 읽습니다. 괄호·혼합 연산·문자는 이번 판정에 넣지 않습니다.',
    );
  }
  final left = BigInt.parse(match.group(1)!);
  final right = BigInt.parse(match.group(3)!);
  if (digitCount(left) > maxOperandDigits || digitCount(right) > maxOperandDigits) {
    return ParsedExpression(
      status: ParseStatus.tooLong,
      display: raw.trim(),
      message: '한 수가 $maxOperandDigits자리를 넘으면 이번 추출기는 거절합니다.',
    );
  }
  final symbol = match.group(2)!;
  final op = switch (symbol) {
    '+' => ArithmeticOp.add,
    '-' => ArithmeticOp.sub,
    '*' => ArithmeticOp.mul,
    '/' => ArithmeticOp.div,
    _ => null,
  };
  if (op == null) {
    return ParsedExpression(status: ParseStatus.unsupported, display: raw.trim(), message: '연산을 읽지 못했습니다.');
  }
  if (op == ArithmeticOp.div && right == BigInt.zero) {
    return ParsedExpression(status: ParseStatus.divZero, display: raw.trim(), message: '0으로 나눌 수 없습니다.');
  }
  return ParsedExpression(status: ParseStatus.ok, display: raw.trim(), left: left, right: right, op: op);
}

NaturalFeatures? extractFeatures(String raw) {
  final parsed = parseNaturalExpression(raw);
  if (!parsed.ok) return null;
  return featuresOf(parsed.left!, parsed.right!, parsed.op!, parsed.display);
}

NaturalFeatures featuresOf(BigInt left, BigInt right, ArithmeticOp op, String display) {
  final canonical = _fingerprint(op, left, right);
  BigInt? result;
  int? carryCount;
  int? carryChain;
  bool? leading;
  int? borrowCount;
  int? borrowChain;
  int? zeroCross;
  int? digitMuls;
  int? nontrivial;
  int? partials;
  int? nonzeroPartials;
  int? mulCarry;
  int? sumCarry;
  int? zeroMulDigits;
  BigInt? quotient;
  BigInt? remainder;
  int? qDigits;
  int? internalZero;
  int? trailingZero;
  int? steps;
  int? bring;
  int? nonzeroQ;
  final aLess = op == ArithmeticOp.sub && left < right;
  if (op == ArithmeticOp.add) {
    result = left + right;
    final info = _addCarry(left, right);
    carryCount = info.$1;
    carryChain = info.$2;
    leading = info.$3;
  } else if (op == ArithmeticOp.sub && !aLess) {
    result = left - right;
    final info = _borrow(left, right);
    borrowCount = info.$1;
    borrowChain = info.$2;
    zeroCross = info.$3;
  } else if (op == ArithmeticOp.mul) {
    result = left * right;
    final info = _multiply(left, right);
    digitMuls = info.digitMuls;
    nontrivial = info.nontrivial;
    partials = info.partials;
    nonzeroPartials = info.nonzeroPartials;
    mulCarry = info.mulCarry;
    sumCarry = info.sumCarry;
    zeroMulDigits = info.zeroDigits;
  } else if (op == ArithmeticOp.div) {
    final info = _divide(left, right);
    quotient = info.quotient;
    remainder = info.remainder;
    qDigits = info.quotientDigits;
    internalZero = info.internalZeros;
    trailingZero = info.trailingZeros;
    steps = info.steps;
    bring = info.bringDowns;
    nonzeroQ = info.nonzeroDigits;
    result = quotient;
  }
  return NaturalFeatures(
    display: display,
    op: op,
    left: left,
    right: right,
    leftDigits: digitCount(left),
    rightDigits: digitCount(right),
    resultDigits: result == null ? null : digitCount(result),
    fingerprint: canonical,
    containsZeroOperand: left == BigInt.zero || right == BigInt.zero,
    containsOneOperand: left == BigInt.one || right == BigInt.one,
    equalOperands: left == right,
    powerOfTenOperand: _powerOfTen(left) || _powerOfTen(right),
    multipleOfTenOperand: _multipleOfTen(left) || _multipleOfTen(right),
    aLessThanB: aLess,
    carryCount: carryCount,
    carryChainLength: carryChain,
    leadingCarry: leading,
    borrowCount: borrowCount,
    borrowChainLength: borrowChain,
    zeroCrossingCount: zeroCross,
    digitMultiplicationCount: digitMuls,
    nontrivialDigitMultiplicationCount: nontrivial,
    partialProductCount: partials,
    nonzeroPartialProductCount: nonzeroPartials,
    multiplicationCarryCount: mulCarry,
    partialSumCarryCount: sumCarry,
    zeroMultiplierDigitCount: zeroMulDigits,
    quotient: quotient,
    remainder: remainder,
    quotientDigits: qDigits,
    internalQuotientZeroCount: internalZero,
    trailingQuotientZeroCount: trailingZero,
    divisionStepCount: steps,
    bringDownCount: bring,
    nonzeroQuotientDigitCount: nonzeroQ,
  );
}

int digitCount(BigInt n) {
  if (n < BigInt.zero) throw ArgumentError('음수 자릿수는 세지 않습니다.');
  if (n == BigInt.zero) return 1;
  return n.toString().length;
}

List<int> digitsLsd(BigInt n) {
  if (n == BigInt.zero) return [0];
  final out = <int>[];
  var x = n;
  while (x > BigInt.zero) {
    out.add((x % BigInt.from(10)).toInt());
    x = x ~/ BigInt.from(10);
  }
  return out;
}

bool _powerOfTen(BigInt n) {
  if (n < BigInt.from(10)) return false;
  var x = n;
  while (x % BigInt.from(10) == BigInt.zero) {
    x = x ~/ BigInt.from(10);
  }
  return x == BigInt.one;
}

bool _multipleOfTen(BigInt n) => n >= BigInt.from(10) && n % BigInt.from(10) == BigInt.zero;

String _fingerprint(ArithmeticOp op, BigInt left, BigInt right) {
  if (op == ArithmeticOp.add || op == ArithmeticOp.mul) {
    final pair = [left, right]..sort();
    return '${op.name}:${pair[0]}:${pair[1]}';
  }
  return '${op.name}:$left:$right';
}

(int, int, bool) _addCarry(BigInt a, BigInt b) {
  final da = digitsLsd(a);
  final db = digitsLsd(b);
  final n = math.max(da.length, db.length);
  var carry = 0;
  var count = 0;
  var chain = 0;
  var maxChain = 0;
  var leading = false;
  for (var i = 0; i < n || carry > 0; i++) {
    final sum = (i < da.length ? da[i] : 0) + (i < db.length ? db[i] : 0) + carry;
    if (sum >= 10) {
      count++;
      chain++;
      if (chain > maxChain) maxChain = chain;
      if (i == n - 1) leading = true;
      carry = sum ~/ 10;
    } else {
      chain = 0;
      carry = 0;
    }
    if (i > n + 4) break;
  }
  return (count, maxChain, leading);
}

(int, int, int) _borrow(BigInt a, BigInt b) {
  final work = digitsLsd(a);
  final sub = digitsLsd(b);
  final n = math.max(work.length, sub.length);
  while (work.length < n) {
    work.add(0);
  }
  while (sub.length < n) {
    sub.add(0);
  }
  var count = 0;
  var chain = 0;
  var maxChain = 0;
  var cross = 0;
  for (var i = 0; i < n; i++) {
    if (work[i] < sub[i]) {
      count++;
      chain++;
      var j = i + 1;
      while (j < n && work[j] == 0) {
        cross++;
        count++;
        chain++;
        work[j] = 9;
        j++;
      }
      if (j < n) work[j] -= 1;
      work[i] += 10;
      if (chain > maxChain) maxChain = chain;
    } else {
      chain = 0;
    }
    work[i] -= sub[i];
  }
  return (count, maxChain, cross);
}

class _MulInfo {
  const _MulInfo({
    required this.digitMuls,
    required this.nontrivial,
    required this.partials,
    required this.nonzeroPartials,
    required this.mulCarry,
    required this.sumCarry,
    required this.zeroDigits,
  });

  final int digitMuls;
  final int nontrivial;
  final int partials;
  final int nonzeroPartials;
  final int mulCarry;
  final int sumCarry;
  final int zeroDigits;
}

/// 오른쪽 인수를 승수로 둔 세로셈. 부분곱 합산은 자리별로 모은 뒤 올림한다.
_MulInfo _multiply(BigInt left, BigInt right) {
  final a = digitsLsd(left);
  final b = digitsLsd(right);
  var digitMuls = 0;
  var nontrivial = 0;
  var mulCarry = 0;
  var zeroDigits = 0;
  var nonzero = 0;
  final partials = <BigInt>[];
  for (var i = 0; i < b.length; i++) {
    final d = b[i];
    if (d == 0) zeroDigits++;
    if (d != 0) nonzero++;
    var carry = 0;
    for (final da in a) {
      digitMuls++;
      if (da >= 2 && d >= 2) nontrivial++;
      final prod = da * d + carry;
      if (prod >= 10) {
        mulCarry++;
        carry = prod ~/ 10;
      } else {
        carry = 0;
      }
    }
    partials.add(left * BigInt.from(d) * BigInt.from(10).pow(i));
  }
  return _MulInfo(
    digitMuls: digitMuls,
    nontrivial: nontrivial,
    partials: b.length,
    nonzeroPartials: nonzero,
    mulCarry: mulCarry,
    sumCarry: _sumCarry(partials),
    zeroDigits: zeroDigits,
  );
}

int _sumCarry(List<BigInt> values) {
  final columns = [for (final v in values) digitsLsd(v)];
  var width = 1;
  for (final col in columns) {
    if (col.length > width) width = col.length;
  }
  var carry = 0;
  var events = 0;
  for (var i = 0; i < width || carry > 0; i++) {
    var sum = carry;
    for (final col in columns) {
      if (i < col.length) sum += col[i];
    }
    if (sum >= 10) {
      events++;
      carry = sum ~/ 10;
    } else {
      carry = 0;
    }
    if (i > width + 8) break;
  }
  return events;
}

class _DivInfo {
  const _DivInfo({
    required this.quotient,
    required this.remainder,
    required this.quotientDigits,
    required this.internalZeros,
    required this.trailingZeros,
    required this.steps,
    required this.bringDowns,
    required this.nonzeroDigits,
  });

  final BigInt quotient;
  final BigInt remainder;
  final int quotientDigits;
  final int internalZeros;
  final int trailingZeros;
  final int steps;
  final int bringDowns;
  final int nonzeroDigits;
}

/// 표준 긴 나눗셈. 몫의 선행 0은 출력하지 않는다.
_DivInfo _divide(BigInt dividend, BigInt divisor) {
  if (divisor == BigInt.zero) {
    throw ArgumentError('0으로 나눌 수 없습니다.');
  }
  final q = dividend ~/ divisor;
  final r = dividend - q * divisor;
  final qDigitList = digitsLsd(q).reversed.toList();
  final trailing = _trailingZeros(qDigitList);
  final bodyEnd = qDigitList.length - trailing;
  var internal = 0;
  for (var i = 0; i < bodyEnd; i++) {
    if (qDigitList[i] == 0) internal++;
  }
  final digits = dividend == BigInt.zero ? [0] : digitsLsd(dividend).reversed.toList();
  var rem = BigInt.zero;
  var started = false;
  var steps = 0;
  var bring = 0;
  for (var i = 0; i < digits.length; i++) {
    rem = rem * BigInt.from(10) + BigInt.from(digits[i]);
    if (!started && rem < divisor && i != digits.length - 1) continue;
    steps++;
    if (started) bring++;
    final qd = rem ~/ divisor;
    rem = rem - qd * divisor;
    started = true;
  }
  return _DivInfo(
    quotient: q,
    remainder: r,
    quotientDigits: digitCount(q),
    internalZeros: internal,
    trailingZeros: trailing,
    steps: steps,
    bringDowns: bring,
    nonzeroDigits: qDigitList.where((d) => d > 0).length,
  );
}

int _trailingZeros(List<int> msdDigits) {
  if (msdDigits.length == 1 && msdDigits.first == 0) return 0;
  var t = 0;
  for (var i = msdDigits.length - 1; i >= 0 && msdDigits[i] == 0; i--) {
    t++;
  }
  return t;
}
