import 'addition_engine.dart';
import '../scoring.dart';

/// 표준 시간 대비 실제 시간의 비율. 100보다 크면 기준보다 빠르다. 상한 없음.
double? efficiencyIndex(List<double> standardOverActual) {
  if (standardOverActual.isEmpty) return null;
  if (standardOverActual.any((r) => r <= 0 || r.isNaN || r.isInfinite)) {
    throw ArgumentError('효율 비율은 유한한 양수여야 합니다.');
  }
  return 100 * median(standardOverActual);
}

/// 속도는 효율을 100에서 자른 값이다.
double? cappedSpeed(double? efficiency) {
  if (efficiency == null) return null;
  return efficiency > 100 ? 100 : efficiency;
}

class AdditionStep {
  const AdditionStep({required this.analysis, required this.index});

  final AdditionAnalysis analysis;
  final int index;
}

class CompositeAddition {
  const CompositeAddition({
    required this.operands,
    required this.steps,
    required this.sum,
    required this.display,
    required this.costMilli,
    required this.timeMs,
    required this.totalCarry,
    required this.seed,
  });

  final List<BigInt> operands;
  final List<AdditionStep> steps;
  final BigInt sum;
  final String display;
  final int costMilli;
  final int timeMs;
  final int totalCarry;
  final AdditionSeed seed;

  double get costPoints => costMilli / 1000;
  bool get hasCarry => totalCarry > 0;
}

CompositeAddition analyzeOperands(List<BigInt> operands, {AdditionSeed seed = AdditionSeed.v3}) {
  if (operands.length < 2) {
    throw ArgumentError('덧셈은 두 수 이상이어야 합니다.');
  }
  if (operands.length == 2) {
    final one = analyzeAddition(operands[0], operands[1], seed: seed);
    return CompositeAddition(
      operands: operands,
      steps: [AdditionStep(analysis: one, index: 0)],
      sum: one.sum,
      display: '${operands[0]}+${operands[1]}',
      costMilli: one.costMilli,
      timeMs: one.timeMs,
      totalCarry: one.features.carryCount,
      seed: seed,
    );
  }
  final steps = <AdditionStep>[];
  var acc = operands[0];
  var cost = 0;
  var carry = 0;
  for (var i = 1; i < operands.length; i++) {
    final step = analyzeAddition(acc, operands[i], seed: seed);
    steps.add(AdditionStep(analysis: step, index: i - 1));
    acc = step.sum;
    cost += step.costMilli;
    carry += step.features.carryCount;
  }
  return CompositeAddition(
    operands: operands,
    steps: steps,
    sum: acc,
    display: operands.join('+'),
    costMilli: cost,
    timeMs: _multiTime(operands, steps, seed),
    totalCarry: carry,
    seed: seed,
  );
}

int _multiTime(List<BigInt> operands, List<AdditionStep> steps, AdditionSeed seed) {
  const overhead = 700;
  const processingBase = 300;
  var processing = 0;
  for (final step in steps) {
    var raw = 0;
    for (final term in step.analysis.terms) {
      if (term.key == 'extra_input' || term.key == 'extra_output') continue;
      if (term.key == 'base') {
        raw += processingBase * term.x;
      } else {
        raw += term.timeMs;
      }
    }
    if (raw < 0) raw = 0;
    processing += raw;
  }
  final inputDigits = operands.fold<int>(0, (s, n) => s + (n == BigInt.zero ? 1 : n.toString().length));
  final answerDigits = steps.last.analysis.sum == BigInt.zero ? 1 : steps.last.analysis.sum.toString().length;
  final total = overhead +
      processing +
      seed.coeff('extra_input').timeMs * (inputDigits - 2) +
      seed.coeff('extra_output').timeMs * (answerDigits - 1) +
      150 * (operands.length - 2);
  return total < seed.timeFloorMs ? seed.timeFloorMs : total;
}

CompositeAddition? parseAdditionList(String raw, {AdditionSeed seed = AdditionSeed.v3}) {
  final parts = raw.replaceAll(' ', '').split('+');
  if (parts.length < 2) return null;
  final nums = <BigInt>[];
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0')) || !RegExp(r'^\d+$').hasMatch(part)) {
      return null;
    }
    if (part.length > additionOperandDigitCap) return null;
    nums.add(BigInt.parse(part));
  }
  return analyzeOperands(nums, seed: seed);
}

/// 가장 큰 나머지 방식. 소수부가 같으면 앞 구간이 먼저 받는다.
List<int> hamiltonQuotas(int count, List<int> weights) {
  if (weights.isEmpty || count < 0) return const [];
  final active = weights.fold<int>(0, (s, w) => s + (w < 0 ? 0 : w));
  if (active == 0 || count == 0) return List<int>.filled(weights.length, 0);
  final exact = <double>[for (final w in weights) (w <= 0 ? 0 : count * w / active)];
  final quotas = [for (final value in exact) value.floor()];
  var left = count - quotas.fold<int>(0, (s, n) => s + n);
  final order = [for (var i = 0; i < weights.length; i++) i]
    ..sort((a, b) {
      final frac = (exact[b] - exact[b].floor()).compareTo(exact[a] - exact[a].floor());
      return frac != 0 ? frac : a.compareTo(b);
    });
  for (final index in order) {
    if (left == 0) break;
    if (weights[index] <= 0) continue;
    quotas[index] += 1;
    left -= 1;
  }
  return quotas;
}

class BandCut {
  const BandCut({required this.edgesMilli, required this.counts});

  /// 길이 4. 비용(milli)이 이 값 이하면 1,2,3,4구간. 그보다 크면 5구간.
  final List<int> edgesMilli;
  final List<int> counts;

  int bandOf(int costMilli) {
    for (var i = 0; i < edgesMilli.length; i++) {
      if (costMilli <= edgesMilli[i]) return i + 1;
    }
    return 5;
  }
}

int percentileIndex(int length, double p) {
  if (length <= 0) return 0;
  final raw = (p * length).ceil() - 1;
  if (raw < 0) return 0;
  if (raw >= length) return length - 1;
  return raw;
}

BandCut cutFiveBands(List<int> costsMilli) {
  final sorted = [...costsMilli]..sort();
  if (sorted.isEmpty) {
    return const BandCut(edgesMilli: [0, 0, 0, 0], counts: [0, 0, 0, 0, 0]);
  }
  final edges = [
    for (final p in [0.2, 0.4, 0.6, 0.8]) sorted[percentileIndex(sorted.length, p)],
  ];
  final counts = List<int>.filled(5, 0);
  for (final cost in sorted) {
    var band = 4;
    for (var i = 0; i < edges.length; i++) {
      if (cost <= edges[i]) {
        band = i;
        break;
      }
    }
    counts[band] += 1;
  }
  return BandCut(edgesMilli: edges, counts: counts);
}

enum CarryFilter { none, some, mixed }

class TrainingItem {
  const TrainingItem({
    required this.expr,
    required this.answer,
    required this.costMilli,
    required this.timeMs,
    required this.band,
    required this.hasCarry,
  });

  final String expr;
  final String answer;
  final int costMilli;
  final int timeMs;
  final int band;
  final bool hasCarry;

  Map<String, Object?> toJson() => {
        'expr': expr,
        'answer': answer,
        'costMilli': costMilli,
        'timeMs': timeMs,
        'band': band,
        'hasCarry': hasCarry,
      };
}

class TrainingRequest {
  const TrainingRequest({
    required this.digits,
    required this.carry,
    required this.count,
    required this.bands,
    required this.weights,
    required this.seed,
    this.allowZero = false,
    this.rule,
  });

  final List<int> digits;
  final CarryFilter carry;
  final int count;
  final List<bool> bands;
  final List<int> weights;
  final int seed;
  final bool allowZero;
  final AdditionRule? rule;
}

class TrainingResult {
  const TrainingResult({
    required this.items,
    required this.quotas,
    required this.actualCounts,
    required this.edges,
    required this.short,
    required this.note,
    required this.approximate,
    required this.withCarry,
    required this.withoutCarry,
  });

  final List<TrainingItem> items;
  final List<int> quotas;
  final List<int> actualCounts;
  final BandCut edges;
  final bool short;
  final String note;
  final bool approximate;
  final int withCarry;
  final int withoutCarry;
}

TrainingResult _emptyResult(String note) {
  return TrainingResult(
    items: const [],
    quotas: const [0, 0, 0, 0, 0],
    actualCounts: const [0, 0, 0, 0, 0],
    edges: const BandCut(edgesMilli: [0, 0, 0, 0], counts: [0, 0, 0, 0, 0]),
    short: true,
    note: note,
    approximate: false,
    withCarry: 0,
    withoutCarry: 0,
  );
}

/// 구간 경계용 표본 시드. 문항을 뽑는 시드와 분리한다.
int distributionSeed(TrainingRequest request) {
  var hash = 0x9e3779b9;
  for (final digit in request.digits) {
    hash = (hash * 33 + digit) & 0x7fffffff;
  }
  hash = (hash * 33 + request.carry.index) & 0x7fffffff;
  hash = (hash * 33 + (request.allowZero ? 1 : 0)) & 0x7fffffff;
  final rule = request.rule;
  if (rule != null) {
    for (final code in rule.id.codeUnits) {
      hash = (hash * 33 + code) & 0x7fffffff;
    }
  }
  return hash == 0 ? 1 : hash;
}

TrainingResult generateAdditionSet(TrainingRequest request, {AdditionSeed seed = AdditionSeed.v3}) {
  final clash = request.rule == null ? null : additionRuleClash(request);
  if (clash != null) return _emptyResult(clash);
  final pool = _pool(request, seed);
  final approximate = pool.approximate;
  final cut = cutFiveBands([for (final item in pool.items) item.costMilli]);
  final banded = List.generate(5, (_) => <TrainingItem>[]);
  for (final item in pool.items) {
    final band = cut.bandOf(item.costMilli);
    banded[band - 1].add(TrainingItem(
      expr: item.display,
      answer: item.sum.toString(),
      costMilli: item.costMilli,
      timeMs: item.timeMs,
      band: band,
      hasCarry: item.hasCarry,
    ));
  }
  for (final list in banded) {
    list.sort((a, b) => a.expr.compareTo(b.expr));
    _shuffle(list, Lcg(request.seed));
  }
  final weights = [
    for (var i = 0; i < 5; i++) request.bands[i] ? request.weights[i] : 0,
  ];
  final quotas = hamiltonQuotas(request.count, weights);
  final chosen = <TrainingItem>[];
  final seen = <String>{};
  for (var i = 0; i < 5; i++) {
    var need = quotas[i];
    if (request.carry == CarryFilter.mixed && need > 1) {
      final withCarry = [for (final item in banded[i]) if (item.hasCarry) item];
      final without = [for (final item in banded[i]) if (!item.hasCarry) item];
      final half = need ~/ 2;
      need -= _take(chosen, seen, withCarry, half);
      need -= _take(chosen, seen, without, need);
      _take(chosen, seen, withCarry, need);
    } else if (request.carry == CarryFilter.some) {
      _take(chosen, seen, [for (final item in banded[i]) if (item.hasCarry) item], need);
    } else if (request.carry == CarryFilter.none) {
      _take(chosen, seen, [for (final item in banded[i]) if (!item.hasCarry) item], need);
    } else {
      _take(chosen, seen, banded[i], need);
    }
  }
  _shuffle(chosen, Lcg(request.seed + 1));
  final actual = List<int>.filled(5, 0);
  var withCarry = 0;
  var withoutCarry = 0;
  for (final item in chosen) {
    actual[item.band - 1] += 1;
    if (item.hasCarry) {
      withCarry += 1;
    } else {
      withoutCarry += 1;
    }
  }
  final lacking = <String>[];
  for (var i = 0; i < 5; i++) {
    if (quotas[i] > actual[i]) lacking.add('${i + 1}구간 ${actual[i]}/${quotas[i]}');
  }
  final short = chosen.length < request.count;
  final note = StringBuffer(
    short
        ? '조건에 맞는 문항이 ${chosen.length}개뿐입니다. ${lacking.join(', ')}. 선택하지 않은 구간이나 자릿수로 넘기지 않았습니다.'
        : '요청한 문항을 모두 만들었습니다.',
  );
  if (approximate) note.write(' 탐색 한도 안의 표본이라 구간 경계는 근사입니다.');
  if (request.carry == CarryFilter.mixed && chosen.isNotEmpty) {
    note.write(' 받아올림 $withCarry개, 없음 $withoutCarry개.');
  }
  return TrainingResult(
    items: chosen,
    quotas: quotas,
    actualCounts: actual,
    edges: cut,
    short: short,
    note: note.toString(),
    approximate: approximate,
    withCarry: withCarry,
    withoutCarry: withoutCarry,
  );
}

int _take(List<TrainingItem> out, Set<String> seen, List<TrainingItem> source, int need) {
  var took = 0;
  for (final item in source) {
    if (took >= need) break;
    if (seen.contains(item.expr)) continue;
    final parts = item.expr.split('+');
    if (parts.length == 2 && parts[0] != parts[1] && seen.contains('${parts[1]}+${parts[0]}')) {
      continue;
    }
    seen.add(item.expr);
    if (parts.length == 2) seen.add('${parts[1]}+${parts[0]}');
    out.add(item);
    took++;
  }
  return took;
}

void _shuffle(List<TrainingItem> items, Lcg random) {
  for (var i = items.length - 1; i > 0; i--) {
    final j = random.nextInt(i + 1);
    final swap = items[i];
    items[i] = items[j];
    items[j] = swap;
  }
}

class _Pool {
  const _Pool(this.items, this.approximate);
  final List<CompositeAddition> items;
  final bool approximate;
}

_Pool _pool(TrainingRequest request, AdditionSeed seed) {
  final ranges = [for (final d in request.digits) _range(d, request.allowZero)];
  var space = 1;
  for (final range in ranges) {
    space *= range.$2 - range.$1 + 1;
    if (space > 20000) break;
  }
  if (ranges.isEmpty) return const _Pool([], false);
  if (space > 20000) return _Pool(_sample(request, seed, ranges), true);
  return _Pool(_enumerate(request, seed, ranges), false);
}

List<CompositeAddition> _sample(TrainingRequest request, AdditionSeed seed, List<(int, int)> ranges) {
  final random = Lcg(distributionSeed(request));
  final out = <CompositeAddition>[];
  final seen = <String>{};
  for (var attempt = 0; attempt < 20000 && out.length < 4000; attempt++) {
    final nums = <BigInt>[];
    for (final range in ranges) {
      final span = range.$2 - range.$1 + 1;
      nums.add(BigInt.from(range.$1 + random.nextInt(span)));
    }
    final item = analyzeOperands(nums, seed: seed);
    final ok = switch (request.carry) {
      CarryFilter.none => !item.hasCarry,
      CarryFilter.some => item.hasCarry,
      CarryFilter.mixed => true,
    };
    if (!ok || !_passesRule(request, item) || !seen.add(item.display)) continue;
    out.add(item);
  }
  return out;
}

List<CompositeAddition> _enumerate(TrainingRequest request, AdditionSeed seed, List<(int, int)> ranges) {
  final out = <CompositeAddition>[];
  void walk(int index, List<BigInt> acc) {
    if (out.length > 50000) return;
    if (index == ranges.length) {
      final item = analyzeOperands(acc, seed: seed);
      final ok = switch (request.carry) {
        CarryFilter.none => !item.hasCarry,
        CarryFilter.some => item.hasCarry,
        CarryFilter.mixed => true,
      };
      if (ok && _passesRule(request, item)) out.add(item);
      return;
    }
    for (var value = ranges[index].$1; value <= ranges[index].$2; value++) {
      if (out.length >= 50000) break;
      acc.add(BigInt.from(value));
      walk(index + 1, acc);
      acc.removeLast();
    }
  }

  if (ranges.isEmpty) return out;
  walk(0, []);
  return out;
}

(int, int) _range(int digits, bool allowZero) {
  if (digits <= 1) return (allowZero ? 0 : 1, 9);
  final start = _pow10(digits - 1);
  return (start, _pow10(digits) - 1);
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

bool _passesRule(TrainingRequest request, CompositeAddition item) {
  final rule = request.rule;
  if (rule == null) return true;
  return explainAdditionRule(rule, item).allowed;
}

/// 교육과정이 생성기에 넘기는 선언 규칙. 학년 번호를 넣지 않는다.
class AdditionRule {
  const AdditionRule({
    required this.id,
    required this.label,
    required this.sourceKind,
    this.minArity,
    this.maxArity,
    this.minDigits,
    this.maxDigits,
    this.minValue,
    this.maxValue,
    this.allowZero = false,
    this.digitPattern = const [],
    this.resultMin,
    this.resultMax,
    this.intermediateMax,
    this.totalCarryEquals,
    this.higherPlaceCarryAllowed = true,
    this.examples = const [],
  });

  final String id;
  final String label;
  final String sourceKind;
  final int? minArity;
  final int? maxArity;
  final int? minDigits;
  final int? maxDigits;
  final String? minValue;
  final String? maxValue;
  final bool allowZero;
  final List<int> digitPattern;
  final String? resultMin;
  final String? resultMax;
  final String? intermediateMax;
  final int? totalCarryEquals;
  final bool higherPlaceCarryAllowed;
  final List<RuleExample> examples;
}

class RuleExample {
  const RuleExample(this.expr, this.allowed);
  final String expr;
  final bool allowed;
}

class RuleDecision {
  const RuleDecision({required this.allowed, required this.reasons});
  final bool allowed;
  final List<String> reasons;
}

const demoAdditionRules = <AdditionRule>[
  AdditionRule(
    id: 'demo_sum_at_most_9',
    label: '한 자리 두 수, 합 9 이하',
    sourceKind: 'demo_only',
    minArity: 2,
    maxArity: 2,
    minDigits: 1,
    maxDigits: 1,
    minValue: '1',
    maxValue: '9',
    resultMax: '9',
    examples: [RuleExample('4+5', true), RuleExample('7+8', false)],
  ),
  AdditionRule(
    id: 'demo_sum_equals_10',
    label: '한 자리 두 수, 합 10',
    sourceKind: 'demo_only',
    minArity: 2,
    maxArity: 2,
    minDigits: 1,
    maxDigits: 1,
    minValue: '1',
    maxValue: '9',
    resultMin: '10',
    resultMax: '10',
    examples: [RuleExample('7+3', true), RuleExample('4+5', false)],
  ),
  AdditionRule(
    id: 'demo_three_under_10',
    label: '한 자리 세 수, 중간 합과 최종 합 10 이하',
    sourceKind: 'demo_only',
    minArity: 3,
    maxArity: 3,
    minDigits: 1,
    maxDigits: 1,
    minValue: '1',
    maxValue: '9',
    resultMax: '10',
    intermediateMax: '10',
    examples: [RuleExample('2+3+4', true), RuleExample('6+5+1', false)],
  ),
  AdditionRule(
    id: 'demo_two_digit_no_carry',
    label: '두 자리 두 수, 받아올림 없음',
    sourceKind: 'demo_only',
    minArity: 2,
    maxArity: 2,
    minDigits: 2,
    maxDigits: 2,
    totalCarryEquals: 0,
    examples: [RuleExample('23+45', true), RuleExample('27+48', false)],
  ),
  AdditionRule(
    id: 'demo_ones_carry_only',
    label: '두 자리 두 수, 십의 자리 받아올림 없음',
    sourceKind: 'demo_only',
    minArity: 2,
    maxArity: 2,
    minDigits: 2,
    maxDigits: 2,
    higherPlaceCarryAllowed: false,
    examples: [RuleExample('27+48', true), RuleExample('78+57', false)],
  ),
  AdditionRule(
    id: 'demo_two_plus_one_under_100',
    label: '두 자리와 한 자리, 합 99 이하',
    sourceKind: 'demo_only',
    minArity: 2,
    maxArity: 2,
    digitPattern: [2, 1],
    resultMax: '99',
    examples: [RuleExample('23+4', true), RuleExample('98+7', false)],
  ),
];

bool demoSumAtMost9(CompositeAddition item) => explainAdditionRule(demoAdditionRules[0], item).allowed;

bool demoSumEquals10(CompositeAddition item) => explainAdditionRule(demoAdditionRules[1], item).allowed;

String? validateAdditionRule(AdditionRule rule) {
  if (rule.sourceKind != 'demo_only' && rule.sourceKind != 'registered') {
    return '규칙 출처를 알 수 없습니다.';
  }
  if (rule.minArity != null && rule.maxArity != null && rule.minArity! > rule.maxArity!) {
    return '항 개수 범위가 뒤집혔습니다.';
  }
  if (rule.minDigits != null && rule.maxDigits != null && rule.minDigits! > rule.maxDigits!) {
    return '자릿수 범위가 뒤집혔습니다.';
  }
  final low = _parseBound(rule.resultMin);
  final high = _parseBound(rule.resultMax);
  if (rule.resultMin != null && low == null) return '합의 하한이 수가 아닙니다.';
  if (rule.resultMax != null && high == null) return '합의 상한이 수가 아닙니다.';
  if (low != null && high != null && low > high) return '합 범위가 뒤집혔습니다.';
  if (rule.intermediateMax != null && _parseBound(rule.intermediateMax) == null) {
    return '중간 합 상한이 수가 아닙니다.';
  }
  if (rule.minValue != null && _parseBound(rule.minValue) == null) return '수 하한이 수가 아닙니다.';
  if (rule.maxValue != null && _parseBound(rule.maxValue) == null) return '수 상한이 수가 아닙니다.';
  return null;
}

String? additionRuleClash(TrainingRequest request) {
  final rule = request.rule;
  if (rule == null) return null;
  final invalid = validateAdditionRule(rule);
  if (invalid != null) return invalid;
  if (rule.minArity != null && request.digits.length < rule.minArity!) {
    return '항 개수가 규칙보다 적습니다. 규칙을 넓히지 않았습니다.';
  }
  if (rule.maxArity != null && request.digits.length > rule.maxArity!) {
    return '항 개수가 규칙보다 많습니다. 규칙을 넓히지 않았습니다.';
  }
  if (rule.digitPattern.isNotEmpty) {
    if (rule.digitPattern.length != request.digits.length) {
      return '항별 자릿수 규칙과 항 개수가 다릅니다.';
    }
    for (var i = 0; i < request.digits.length; i++) {
      if (request.digits[i] != rule.digitPattern[i]) {
        return '${i + 1}번째 항 자릿수가 규칙과 다릅니다. 규칙을 넓히지 않았습니다.';
      }
    }
  } else {
    for (final digit in request.digits) {
      if (rule.minDigits != null && digit < rule.minDigits!) {
        return '자릿수가 규칙보다 작습니다.';
      }
      if (rule.maxDigits != null && digit > rule.maxDigits!) {
        return '자릿수가 규칙보다 큽니다. 규칙을 넓히지 않았습니다.';
      }
    }
  }
  return null;
}

RuleDecision explainAdditionRule(AdditionRule rule, CompositeAddition item) {
  final reasons = <String>[];
  final invalid = validateAdditionRule(rule);
  if (invalid != null) reasons.add(invalid);
  if (rule.minArity != null && item.operands.length < rule.minArity!) reasons.add('항이 적습니다.');
  if (rule.maxArity != null && item.operands.length > rule.maxArity!) reasons.add('항이 많습니다.');
  final low = _parseBound(rule.minValue);
  final high = _parseBound(rule.maxValue);
  for (var i = 0; i < item.operands.length; i++) {
    final operand = item.operands[i];
    final digits = operand == BigInt.zero ? 1 : operand.toString().length;
    if (rule.digitPattern.isNotEmpty) {
      if (i >= rule.digitPattern.length || digits != rule.digitPattern[i]) {
        reasons.add('${i + 1}번째 항 자릿수가 규칙과 다릅니다.');
      }
    } else {
      if (rule.minDigits != null && digits < rule.minDigits!) reasons.add('${i + 1}번째 항 자릿수가 작습니다.');
      if (rule.maxDigits != null && digits > rule.maxDigits!) reasons.add('${i + 1}번째 항 자릿수가 큽니다.');
    }
    if (!rule.allowZero && operand == BigInt.zero) reasons.add('0을 허용하지 않습니다.');
    if (low != null && operand < low) reasons.add('${i + 1}번째 항이 하한보다 작습니다.');
    if (high != null && operand > high) reasons.add('${i + 1}번째 항이 상한보다 큽니다.');
  }
  final resultMin = _parseBound(rule.resultMin);
  final resultMax = _parseBound(rule.resultMax);
  if (resultMin != null && item.sum < resultMin) reasons.add('합이 하한보다 작습니다.');
  if (resultMax != null && item.sum > resultMax) reasons.add('합이 상한보다 큽니다.');
  final mid = _parseBound(rule.intermediateMax);
  if (mid != null) {
    for (final step in item.steps) {
      if (step.analysis.sum > mid) reasons.add('중간 합이 상한보다 큽니다.');
    }
  }
  if (rule.totalCarryEquals != null && item.totalCarry != rule.totalCarryEquals) {
    reasons.add('받아올림 횟수가 ${rule.totalCarryEquals}이 아닙니다.');
  }
  if (!rule.higherPlaceCarryAllowed && _higherPlaceCarry(item)) {
    reasons.add('십의 자리 이상에서 받아올림이 있습니다.');
  }
  return RuleDecision(allowed: reasons.isEmpty, reasons: reasons);
}

bool _higherPlaceCarry(CompositeAddition item) {
  for (final step in item.steps) {
    for (final column in step.analysis.features.columns) {
      if (column.index > 0 && column.carryOut > 0) return true;
    }
  }
  return false;
}

BigInt? _parseBound(String? raw) {
  if (raw == null || raw.isEmpty || !RegExp(r'^\d+$').hasMatch(raw)) return null;
  return BigInt.parse(raw);
}
