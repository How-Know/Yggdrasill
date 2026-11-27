import 'dart:math' as math;

/// 자연수 덧셈 한 모델. 비용 1점 = 1000 units, 시간은 ms.
const additionModelId = 'natural.addition';
const additionSeedVersion = 'seed_v1';
const additionFeatureSchema = 1;
const additionOperandDigitCap = 8;

class AdditionCoeff {
  const AdditionCoeff({required this.key, required this.costMilli, required this.timeMs});

  final String key;
  final int costMilli;
  final int timeMs;

  AdditionCoeff copy({int? costMilli, int? timeMs}) => AdditionCoeff(
        key: key,
        costMilli: costMilli ?? this.costMilli,
        timeMs: timeMs ?? this.timeMs,
      );
}

class AdditionSeed {
  const AdditionSeed({
    required this.version,
    required this.coeffs,
    required this.costFloorMilli,
    required this.timeFloorMs,
  });

  final String version;
  final List<AdditionCoeff> coeffs;
  final int costFloorMilli;
  final int timeFloorMs;

  static const v1 = AdditionSeed(
    version: additionSeedVersion,
    costFloorMilli: 25,
    timeFloorMs: 350,
    coeffs: [
      AdditionCoeff(key: 'base', costMilli: 100, timeMs: 1000),
      AdditionCoeff(key: 'extra_pair', costMilli: 70, timeMs: 450),
      AdditionCoeff(key: 'solo_digit', costMilli: 35, timeMs: 180),
      AdditionCoeff(key: 'carry', costMilli: 45, timeMs: 350),
      AdditionCoeff(key: 'chain_link', costMilli: 25, timeMs: 150),
      AdditionCoeff(key: 'pair_size_delta', costMilli: 2, timeMs: 20),
      AdditionCoeff(key: 'local_ten', costMilli: -12, timeMs: -100),
      AdditionCoeff(key: 'local_tie', costMilli: -10, timeMs: -80),
      AdditionCoeff(key: 'round_result', costMilli: -25, timeMs: -180),
      AdditionCoeff(key: 'identity', costMilli: -50, timeMs: -300),
      AdditionCoeff(key: 'extra_input', costMilli: 0, timeMs: 80),
      AdditionCoeff(key: 'extra_output', costMilli: 0, timeMs: 180),
    ],
  );

  /// 표준 절차 비용. 전체 합이 100·1000이 되는 할인은 빼고 속성은 남긴다.
  static const v3 = AdditionSeed(
    version: 'seed_v3',
    costFloorMilli: 25,
    timeFloorMs: 350,
    coeffs: [
      AdditionCoeff(key: 'base', costMilli: 100, timeMs: 1000),
      AdditionCoeff(key: 'extra_pair', costMilli: 70, timeMs: 450),
      AdditionCoeff(key: 'solo_digit', costMilli: 35, timeMs: 180),
      AdditionCoeff(key: 'carry', costMilli: 45, timeMs: 350),
      AdditionCoeff(key: 'chain_link', costMilli: 25, timeMs: 150),
      AdditionCoeff(key: 'pair_size_delta', costMilli: 2, timeMs: 20),
      AdditionCoeff(key: 'local_ten', costMilli: -12, timeMs: -100),
      AdditionCoeff(key: 'local_tie', costMilli: -10, timeMs: -80),
      AdditionCoeff(key: 'round_result', costMilli: 0, timeMs: 0),
      AdditionCoeff(key: 'identity', costMilli: -50, timeMs: -300),
      AdditionCoeff(key: 'extra_input', costMilli: 0, timeMs: 80),
      AdditionCoeff(key: 'extra_output', costMilli: 0, timeMs: 180),
    ],
  );

  AdditionCoeff coeff(String key) => coeffs.firstWhere((c) => c.key == key);

  AdditionSeed replace(String key, {int? costMilli, int? timeMs}) {
    return AdditionSeed(
      version: version,
      costFloorMilli: costFloorMilli,
      timeFloorMs: timeFloorMs,
      coeffs: [for (final c in coeffs) c.key == key ? c.copy(costMilli: costMilli, timeMs: timeMs) : c],
    );
  }
}

class AdditionColumn {
  const AdditionColumn({
    required this.index,
    required this.aDigit,
    required this.bDigit,
    required this.aPresent,
    required this.bPresent,
    required this.carryIn,
    required this.rawSum,
    required this.columnTotal,
    required this.resultDigit,
    required this.carryOut,
  });

  final int index;
  final int aDigit;
  final int bDigit;
  final bool aPresent;
  final bool bPresent;
  final int carryIn;
  final int rawSum;
  final int columnTotal;
  final int resultDigit;
  final int carryOut;
}

class AdditionFeatures {
  const AdditionFeatures({
    required this.operandADigits,
    required this.operandBDigits,
    required this.resultDigits,
    required this.effectivePairCount,
    required this.soloNonzeroCount,
    required this.carryCount,
    required this.carryChainMax,
    required this.carryChainLinks,
    required this.localTenCount,
    required this.localTieCount,
    required this.pairSizeDeltaSum,
    required this.isIdentity,
    required this.isRoundResult,
    required this.derived,
    required this.columns,
    required this.carryOuts,
  });

  final int operandADigits;
  final int operandBDigits;
  final int resultDigits;
  final int effectivePairCount;
  final int soloNonzeroCount;
  final int carryCount;
  final int carryChainMax;
  final int carryChainLinks;
  final int localTenCount;
  final int localTieCount;
  final int pairSizeDeltaSum;
  final bool isIdentity;
  final bool isRoundResult;

  /// 비용·시간에 곱하는 값. identity면 solo_digit은 0이다.
  final Map<String, int> derived;
  final List<AdditionColumn> columns;
  final List<int> carryOuts;
}

class AdditionTerm {
  const AdditionTerm({required this.key, required this.x, required this.costMilli, required this.timeMs});

  final String key;
  final int x;
  final int costMilli;
  final int timeMs;
}

class AdditionAnalysis {
  const AdditionAnalysis({
    required this.a,
    required this.b,
    required this.sum,
    required this.display,
    required this.features,
    required this.terms,
    required this.costMilli,
    required this.timeMs,
    required this.costFloorAdjustMilli,
    required this.timeFloorAdjustMs,
    required this.seed,
  });

  final BigInt a;
  final BigInt b;
  final BigInt sum;
  final String display;
  final AdditionFeatures features;
  final List<AdditionTerm> terms;
  final int costMilli;
  final int timeMs;
  final int costFloorAdjustMilli;
  final int timeFloorAdjustMs;
  final AdditionSeed seed;

  double get costPoints => costMilli / 1000;
  double get timeSeconds => timeMs / 1000;
}

class AdditionParse {
  const AdditionParse.ok(this.analysis) : message = '';
  const AdditionParse.fail(this.message) : analysis = null;

  final AdditionAnalysis? analysis;
  final String message;
  bool get ok => analysis != null;
}

AdditionParse parseAddition(String raw, {AdditionSeed seed = AdditionSeed.v1}) {
  var text = raw.trim().replaceAll(' ', '').replaceAll(',', '').replaceAll('＋', '+').replaceAll('−', '');
  if (text.isEmpty) return const AdditionParse.fail('식을 입력해 주세요.');
  final eq = text.indexOf('=');
  String? claimed;
  if (eq >= 0) {
    claimed = text.substring(eq + 1);
    text = text.substring(0, eq);
  }
  final match = RegExp(r'^(\d+)\+(\d+)$').firstMatch(text);
  if (match == null) {
    return const AdditionParse.fail('자연수 두 개의 덧셈만 읽습니다. 예: 378+245');
  }
  final left = match.group(1)!;
  final right = match.group(2)!;
  if (_badLeadingZero(left) || _badLeadingZero(right)) {
    return const AdditionParse.fail('앞에 0이 붙은 수는 받지 않습니다. 0 자체만 허용합니다.');
  }
  if (left.length > additionOperandDigitCap || right.length > additionOperandDigitCap) {
    return AdditionParse.fail('한 수는 $additionOperandDigitCap자리까지입니다.');
  }
  final a = BigInt.parse(left);
  final b = BigInt.parse(right);
  final sum = a + b;
  if (claimed != null && claimed.isNotEmpty) {
    if (_badLeadingZero(claimed) || !RegExp(r'^\d+$').hasMatch(claimed) || BigInt.parse(claimed) != sum) {
      return AdditionParse.fail('등호 뒤의 답이 $sum과 다릅니다.');
    }
  }
  return AdditionParse.ok(analyzeAddition(a, b, seed: seed));
}

bool _badLeadingZero(String digits) => digits.length > 1 && digits.startsWith('0');

AdditionAnalysis analyzeAddition(BigInt a, BigInt b, {AdditionSeed seed = AdditionSeed.v1}) {
  if (a.isNegative || b.isNegative) {
    throw ArgumentError('자연수 덧셈은 0 이상만 받습니다.');
  }
  final columns = _columns(a, b);
  final features = _features(a, b, columns);
  final terms = <AdditionTerm>[];
  var cost = 0;
  var time = 0;
  for (final coeff in seed.coeffs) {
    final x = features.derived[coeff.key] ?? 0;
    final c = coeff.costMilli * x;
    final t = coeff.timeMs * x;
    terms.add(AdditionTerm(key: coeff.key, x: x, costMilli: c, timeMs: t));
    cost += c;
    time += t;
  }
  var costAdjust = 0;
  var timeAdjust = 0;
  if (cost < seed.costFloorMilli) {
    costAdjust = seed.costFloorMilli - cost;
    cost = seed.costFloorMilli;
  }
  if (time < seed.timeFloorMs) {
    timeAdjust = seed.timeFloorMs - time;
    time = seed.timeFloorMs;
  }
  return AdditionAnalysis(
    a: a,
    b: b,
    sum: a + b,
    display: '$a+$b',
    features: features,
    terms: terms,
    costMilli: cost,
    timeMs: time,
    costFloorAdjustMilli: costAdjust,
    timeFloorAdjustMs: timeAdjust,
    seed: seed,
  );
}

List<AdditionColumn> _columns(BigInt a, BigInt b) {
  final da = _lsd(a);
  final db = _lsd(b);
  final n = math.max(da.length, db.length);
  final out = <AdditionColumn>[];
  var carry = 0;
  for (var i = 0; i < n; i++) {
    final aPresent = i < da.length;
    final bPresent = i < db.length;
    final x = aPresent ? da[i] : 0;
    final y = bPresent ? db[i] : 0;
    final raw = x + y;
    final total = raw + carry;
    final column = AdditionColumn(
      index: i,
      aDigit: x,
      bDigit: y,
      aPresent: aPresent,
      bPresent: bPresent,
      carryIn: carry,
      rawSum: raw,
      columnTotal: total,
      resultDigit: total % 10,
      carryOut: total ~/ 10,
    );
    out.add(column);
    carry = column.carryOut;
  }
  return out;
}

List<int> _lsd(BigInt n) {
  if (n == BigInt.zero) return [0];
  final out = <int>[];
  var x = n;
  while (x > BigInt.zero) {
    out.add((x % BigInt.from(10)).toInt());
    x = x ~/ BigInt.from(10);
  }
  return out;
}

int _digits(BigInt n) => n == BigInt.zero ? 1 : n.toString().length;

bool _powerOfTen(BigInt n) {
  if (n < BigInt.from(10)) return false;
  var x = n;
  while (x % BigInt.from(10) == BigInt.zero) {
    x = x ~/ BigInt.from(10);
  }
  return x == BigInt.one;
}

AdditionFeatures _features(BigInt a, BigInt b, List<AdditionColumn> columns) {
  var pairs = 0;
  var solo = 0;
  var carry = 0;
  var links = 0;
  var ten = 0;
  var tie = 0;
  var delta = 0;
  var chain = 0;
  var maxChain = 0;
  final outs = <int>[];
  for (final col in columns) {
    outs.add(col.carryOut);
    if (col.carryOut == 1) {
      carry++;
      chain++;
      if (chain > maxChain) maxChain = chain;
    } else {
      chain = 0;
    }
    if (col.carryIn == 1 && col.carryOut == 1) links++;
    final aOn = col.aDigit > 0;
    final bOn = col.bDigit > 0;
    if (aOn && bOn) {
      pairs++;
      delta += col.rawSum - 5;
      if (col.rawSum == 10) ten++;
      if (col.aDigit == col.bDigit) tie++;
    } else if (aOn != bOn) {
      solo++;
    }
  }
  final sum = a + b;
  final identity = a == BigInt.zero || b == BigInt.zero;
  final maxDigits = math.max(_digits(a), _digits(b));
  final round = a > BigInt.zero && b > BigInt.zero && _powerOfTen(sum) && maxDigits >= 2;
  final resultDigits = _digits(sum);
  final derived = {
    'base': 1,
    'extra_pair': math.max(0, pairs - 1),
    'solo_digit': identity ? 0 : solo,
    'carry': carry,
    'chain_link': links,
    'pair_size_delta': delta,
    'local_ten': ten,
    'local_tie': tie,
    'round_result': round ? 1 : 0,
    'identity': identity ? 1 : 0,
    'extra_input': _digits(a) + _digits(b) - 2,
    'extra_output': resultDigits - 1,
  };
  return AdditionFeatures(
    operandADigits: _digits(a),
    operandBDigits: _digits(b),
    resultDigits: resultDigits,
    effectivePairCount: pairs,
    soloNonzeroCount: solo,
    carryCount: carry,
    carryChainMax: maxChain,
    carryChainLinks: links,
    localTenCount: ten,
    localTieCount: tie,
    pairSizeDeltaSum: delta,
    isIdentity: identity,
    isRoundResult: round,
    derived: derived,
    columns: columns,
    carryOuts: outs,
  );
}

class AdditionPreset {
  const AdditionPreset({
    required this.id,
    required this.legacyCode,
    required this.name,
    required this.example,
    required this.legacyCost,
    required this.legacySeconds,
    required this.matches,
  });

  final String id;
  final String legacyCode;
  final String name;
  final String example;
  final double legacyCost;
  final double legacySeconds;
  final bool Function(AdditionAnalysis analysis) matches;
}

final additionPresets = <AdditionPreset>[
  AdditionPreset(
    id: 'add_11_c0',
    legacyCode: 'nat_add_1d_1d_nc',
    name: '1자리+1자리 (받아올림 없음)',
    example: '2+3',
    legacyCost: 0.10,
    legacySeconds: 1.0,
    matches: (a) => _digitsOf(a, 1, 1) && a.features.carryCount == 0 && !a.features.isIdentity,
  ),
  AdditionPreset(
    id: 'add_11_c1',
    legacyCode: 'nat_add_1d_1d_c1',
    name: '1자리+1자리 (받아올림 있음)',
    example: '7+8',
    legacyCost: 0.15,
    legacySeconds: 1.3,
    matches: (a) => _digitsOf(a, 1, 1) && a.features.carryCount >= 1 && !a.features.isIdentity,
  ),
  AdditionPreset(
    id: 'add_21_c0',
    legacyCode: 'nat_add_2d_1d_nc',
    name: '2자리+1자리 (받아올림 없음)',
    example: '23+4',
    legacyCost: 0.15,
    legacySeconds: 1.8,
    matches: (a) => _span(a, 2, 1) && a.features.carryCount == 0 && !a.features.isIdentity,
  ),
  AdditionPreset(
    id: 'add_21_c1',
    legacyCode: 'nat_add_2d_1d_c1',
    name: '2자리+1자리 (받아올림 1회)',
    example: '27+8',
    legacyCost: 0.22,
    legacySeconds: 2.3,
    matches: (a) => _span(a, 2, 1) && a.features.carryCount == 1,
  ),
  AdditionPreset(
    id: 'add_21_c2',
    legacyCode: 'nat_add_2d_1d_c2',
    name: '2자리+1자리 (연속 받아올림 2회)',
    example: '98+7',
    legacyCost: 0.28,
    legacySeconds: 3.0,
    matches: (a) => _span(a, 2, 1) && a.features.carryCount >= 2,
  ),
  AdditionPreset(
    id: 'add_22_c0',
    legacyCode: 'nat_add_2d_2d_nc',
    name: '2자리+2자리 (받아올림 없음)',
    example: '23+45',
    legacyCost: 0.20,
    legacySeconds: 2.5,
    matches: (a) => _digitsOf(a, 2, 2) && a.features.carryCount == 0,
  ),
  AdditionPreset(
    id: 'add_22_c1',
    legacyCode: 'nat_add_2d_2d_c1',
    name: '2자리+2자리 (받아올림 1회)',
    example: '27+48',
    legacyCost: 0.30,
    legacySeconds: 3.0,
    matches: (a) => _digitsOf(a, 2, 2) && a.features.carryCount == 1,
  ),
  AdditionPreset(
    id: 'add_22_c2',
    legacyCode: 'nat_add_2d_2d_c2',
    name: '2자리+2자리 (받아올림 2회)',
    example: '78+57',
    legacyCost: 0.40,
    legacySeconds: 3.5,
    matches: (a) => _digitsOf(a, 2, 2) && a.features.carryCount >= 2,
  ),
  AdditionPreset(
    id: 'add_3x_c01',
    legacyCode: 'nat_add_3d_23d_c01',
    name: '3자리+2·3자리 (받아올림 0~1회)',
    example: '234+53',
    legacyCost: 0.42,
    legacySeconds: 4.5,
    matches: (a) => _hi(a) == 3 && _lo(a) >= 2 && _lo(a) <= 3 && a.features.carryCount <= 1,
  ),
  AdditionPreset(
    id: 'add_33_c2',
    legacyCode: 'nat_add_3d_3d_c2p',
    name: '3자리+3자리 이상 (받아올림 2회 이상)',
    example: '687+586',
    legacyCost: 0.55,
    legacySeconds: 6.0,
    matches: (a) => _hi(a) >= 3 && _lo(a) >= 3 && a.features.carryCount >= 2,
  ),
];

bool _digitsOf(AdditionAnalysis a, int x, int y) {
  final da = a.features.operandADigits;
  final db = a.features.operandBDigits;
  return (da == x && db == y) || (da == y && db == x);
}

bool _span(AdditionAnalysis a, int hi, int lo) => _hi(a) == hi && _lo(a) == lo;

int _hi(AdditionAnalysis a) => math.max(a.features.operandADigits, a.features.operandBDigits);
int _lo(AdditionAnalysis a) => math.min(a.features.operandADigits, a.features.operandBDigits);

List<AdditionPreset> matchingPresets(AdditionAnalysis analysis) => [
      for (final preset in additionPresets)
        if (preset.matches(analysis)) preset,
    ];

/// 알고리즘 A. 학생별 잔차의 30% 분위수를 시드 기본 시간에 더한다. 비용은 바꾸지 않는다.
class AdditionBiasResult {
  const AdditionBiasResult({
    required this.studentCount,
    required this.quantileMs,
    required this.deltaMs,
    required this.candidateBaseMs,
    required this.reason,
  });

  final int studentCount;
  final double? quantileMs;
  final int? deltaMs;
  final int? candidateBaseMs;
  final String reason;
}

AdditionBiasResult additionBiasCandidate({
  required List<double> studentResidualMs,
  required int priorK,
  required double quantile,
  required int seedBaseMs,
  int minStudents = 10,
}) {
  final n = studentResidualMs.length;
  if (n < minStudents) {
    return AdditionBiasResult(
      studentCount: n,
      quantileMs: n == 0 ? null : _quantile(studentResidualMs, quantile),
      deltaMs: null,
      candidateBaseMs: null,
      reason: '적격 학생 $n명은 $minStudents명 미만이라 후보를 만들지 않습니다.',
    );
  }
  final q = _quantile(studentResidualMs, quantile);
  final shrinkage = n / (n + priorK);
  final delta = _halfAway(shrinkage * q);
  final base = seedBaseMs + delta;
  if (base <= 0) {
    return AdditionBiasResult(
      studentCount: n,
      quantileMs: q,
      deltaMs: null,
      candidateBaseMs: null,
      reason: '보정 뒤 기본 시간이 0 이하라 후보를 거절합니다.',
    );
  }
  return AdditionBiasResult(
    studentCount: n,
    quantileMs: q,
    deltaMs: delta,
    candidateBaseMs: base,
    reason: '기본 시간만 ${delta}ms 옮긴 후보입니다. 다른 계수와 비용은 시드 그대로입니다.',
  );
}

double _quantile(List<double> values, double q) {
  final sorted = [...values]..sort();
  if (sorted.length == 1) return sorted.first;
  final h = (sorted.length - 1) * q;
  final lo = h.floor();
  final hi = h.ceil();
  if (lo == hi) return sorted[lo];
  final w = h - lo;
  return sorted[lo] * (1 - w) + sorted[hi] * w;
}

int _halfAway(double value) {
  final abs = value.abs();
  final rounded = abs - abs.floor() == 0.5 ? abs.floor() + 1 : abs.round();
  return value < 0 ? -rounded : rounded;
}

const additionTermLabels = <String, String>{
  'base': '기본',
  'extra_pair': '추가 열',
  'solo_digit': '한쪽 숫자',
  'carry': '받아올림',
  'chain_link': '연쇄',
  'pair_size_delta': '수의 크기',
  'local_ten': '10 보수',
  'local_tie': '같은 숫자',
  'round_result': '기준수',
  'identity': '0과 더하기',
  'extra_input': '추가 읽기',
  'extra_output': '추가 답 자릿수',
};
