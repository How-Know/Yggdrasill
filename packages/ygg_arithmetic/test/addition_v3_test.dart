import 'package:test/test.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

void main() {
  test('v3는 전체 보수 할인을 빼고 2+3은 그대로다', () {
    final plain = parseAddition('2+3', seed: AdditionSeed.v3).analysis!;
    expect(plain.costPoints, closeTo(0.100, 0.0005));
    expect(plain.timeMs, 1000);
    final round = parseAddition('37+63', seed: AdditionSeed.v3).analysis!;
    expect(round.features.isRoundResult, isTrue);
    expect(round.costPoints, closeTo(0.291, 0.0005));
    expect(round.timeMs, 2900);
    final nines = parseAddition('999+1', seed: AdditionSeed.v3).analysis!;
    expect(nines.costPoints, closeTo(0.353, 0.0005));
    expect(nines.timeMs, 3410);
  });

  test('두 수는 이항 시간과 같고, 세 수 이상은 단계를 나눈다', () {
    final binary = analyzeOperands([BigInt.from(27), BigInt.from(38)]);
    final direct = analyzeAddition(BigInt.from(27), BigInt.from(38), seed: AdditionSeed.v3);
    expect(binary.timeMs, direct.timeMs);
    expect(binary.costMilli, direct.costMilli);
    final many = parseAdditionList('27+38+15+42')!;
    expect(many.sum.toString(), '122');
    expect(many.steps.map((s) => s.analysis.features.carryCount).toList(), [1, 1, 1]);
    expect(many.steps.map((s) => s.analysis.sum.toString()).toList(), ['65', '80', '122']);
    expect(many.costMilli, many.steps.fold<int>(0, (s, step) => s + step.analysis.costMilli));
    expect(parseAdditionList('9+9+9')!.totalCarry, 2);
    expect(parseAdditionList('99+1+1')!.steps.map((s) => s.analysis.features.carryCount).toList(), [2, 0]);
  });

  test('효율 160이면 속도 100, 정확도 98이면 숙련 98', () {
    expect(efficiencyIndex([1.6]), 160);
    expect(cappedSpeed(160), 100);
    final fluency = fluencyScore(speed: 100, accuracy: 98, accuracyEligibleCount: 1, wSpeed: 1, wAccuracy: 1);
    expect(fluency, 98);
    expect(efficiencyIndex(const []), isNull);
  });

  test('비율 배정', () {
    expect(hamiltonQuotas(30, [1, 1, 1, 1, 1]), [6, 6, 6, 6, 6]);
    expect(hamiltonQuotas(30, [0, 1, 1, 1, 0]), [0, 10, 10, 10, 0]);
    expect(hamiltonQuotas(30, [0, 1, 2, 1, 0]), [0, 8, 15, 7, 0]);
    expect(hamiltonQuotas(30, [10, 20, 40, 20, 10]), [3, 6, 12, 6, 3]);
    expect(hamiltonQuotas(7, [1, 1, 1, 1, 1]), [2, 2, 1, 1, 1]);
  });

  test('같은 조건과 시드는 같은 문항을 만든다', () {
    const request = TrainingRequest(
      digits: [1, 1],
      carry: CarryFilter.mixed,
      count: 8,
      bands: [true, true, true, true, true],
      weights: [1, 1, 1, 1, 1],
      seed: 7,
    );
    final a = generateAdditionSet(request);
    final b = generateAdditionSet(request);
    expect(a.items.map((e) => e.expr).toList(), b.items.map((e) => e.expr).toList());
    expect(a.quotas.fold<int>(0, (s, n) => s + n), 8);
    expect(a.short, isFalse);
  });

  test('교육과정 예시는 공식 학년 규칙이 아니다', () {
    expect(demoSumAtMost9(parseAdditionList('4+5')!), isTrue);
    expect(demoSumAtMost9(parseAdditionList('7+8')!), isFalse);
    expect(demoSumEquals10(parseAdditionList('7+3')!), isTrue);
    expect(demoSumEquals10(parseAdditionList('4+5')!), isFalse);
  });

  test('구간 경계는 문항 수와 상관없이 같다', () {
    const base = TrainingRequest(
      digits: [1, 1],
      carry: CarryFilter.none,
      count: 6,
      bands: [true, true, true, true, true],
      weights: [1, 1, 1, 1, 1],
      seed: 3,
    );
    final a = generateAdditionSet(base);
    final b = generateAdditionSet(TrainingRequest(
      digits: base.digits,
      carry: base.carry,
      count: 12,
      bands: base.bands,
      weights: base.weights,
      seed: 99,
    ));
    expect(a.edges.edgesMilli, b.edges.edgesMilli);
  });

  test('후보가 없어도 다른 구간으로 배정을 옮기지 않는다', () {
    final result = generateAdditionSet(const TrainingRequest(
      digits: [1, 1],
      carry: CarryFilter.mixed,
      count: 30,
      bands: [true, true, true, true, true],
      weights: [1, 1, 1, 1, 1],
      seed: 1,
      rule: AdditionRule(
        id: 'demo_impossible',
        label: '합 0',
        sourceKind: 'demo_only',
        minArity: 2,
        maxArity: 2,
        minValue: '1',
        resultMax: '0',
      ),
    ));
    expect(result.items, isEmpty);
    expect(result.quotas, [6, 6, 6, 6, 6]);
    expect(result.short, isTrue);
  });

  test('큰 범위의 구간 경계는 출제 시드와 분리된다', () {
    const digits = [3, 3];
    final first = generateAdditionSet(const TrainingRequest(
      digits: digits,
      carry: CarryFilter.mixed,
      count: 8,
      bands: [true, true, true, true, true],
      weights: [1, 1, 1, 1, 1],
      seed: 1,
    ));
    final second = generateAdditionSet(const TrainingRequest(
      digits: digits,
      carry: CarryFilter.mixed,
      count: 20,
      bands: [true, false, true, false, true],
      weights: [3, 1, 4, 1, 2],
      seed: 9,
    ));
    expect(first.approximate, isTrue);
    expect(first.edges.edgesMilli, second.edges.edgesMilli);
  });

  test('데모 규칙은 예시와 맞고 학년을 정하지 않는다', () {
    expect(validateAdditionRule(const AdditionRule(id: 'bad', label: '뒤집힘', sourceKind: 'demo_only', minArity: 4, maxArity: 2)), '항 개수 범위가 뒤집혔습니다.');
    for (final rule in demoAdditionRules) {
      expect(rule.sourceKind, 'demo_only');
      for (final example in rule.examples) {
        final item = parseAdditionList(example.expr)!;
        expect(explainAdditionRule(rule, item).allowed, example.allowed, reason: '${rule.id} ${example.expr}');
      }
    }
  });
}
