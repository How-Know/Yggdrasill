import 'package:test/test.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

void main() {
  group('속성', () {
    test('덧셈 받아올림', () {
      expect(_f('2+3').carryCount, 0);
      final seven = _f('7+8');
      expect(seven.carryCount, 1);
      expect(seven.leadingCarry, isTrue);
      final chain = _f('98+7');
      expect(chain.carryCount, 2);
      expect(chain.carryChainLength, 2);
      expect(chain.leadingCarry, isTrue);
      final mid = _f('297+8');
      expect(mid.carryCount, 2);
      expect(mid.carryChainLength, 2);
      expect(mid.leadingCarry, isFalse);
      expect(mid.resultDigits, 3);
      final nines = _f('999+1');
      expect(nines.carryCount, 3);
      expect(nines.resultDigits, 4);
    });

    test('뺄셈 받아내림과 0 경유', () {
      expect(_f('43-7').borrowCount, 1);
      expect(_f('43-7').zeroCrossingCount, 0);
      final cross = _f('403-7');
      expect(cross.borrowCount, 2);
      expect(cross.zeroCrossingCount, 1);
      final long = _f('1000-7');
      expect(long.borrowCount, 3);
      expect(long.zeroCrossingCount, 2);
      final chain = _f('532-158');
      expect(chain.borrowCount, 2);
      expect(chain.borrowChainLength, 2);
      expect(chain.zeroCrossingCount, 0);
    });

    test('곱셈 부분곱', () {
      final easy = _f('27*36');
      expect(easy.left * easy.right, BigInt.from(972));
      expect(easy.partialSumCarryCount, 0);
      final hard = _f('87*96');
      expect(hard.left * hard.right, BigInt.from(8352));
      expect(hard.partialSumCarryCount, 1);
      expect(_f('23*4').multiplicationCarryCount, isNot(_f('87*6').multiplicationCarryCount));
    });

    test('나눗셈', () {
      final mid = _f('612/3');
      expect(mid.quotient, BigInt.from(204));
      expect(mid.internalQuotientZeroCount, 1);
      final tail = _f('630/3');
      expect(tail.quotient, BigInt.from(210));
      expect(tail.trailingQuotientZeroCount, 1);
      final qr = _f('937/24');
      expect(qr.quotient, BigInt.from(39));
      expect(qr.remainder, BigInt.one);
      final small = _f('3/7');
      expect(small.quotient, BigInt.zero);
      expect(small.remainder, BigInt.from(3));
      expect(parseNaturalExpression('7/0').status, ParseStatus.divZero);
      expect(parseNaturalExpression('0/0').status, ParseStatus.divZero);
    });

    test('순서를 바꿔도 분류는 같고 표시 순서는 남는다', () {
      final a = _f('8+7');
      final b = _f('7+8');
      expect(a.fingerprint, b.fingerprint);
      expect(a.display, isNot(b.display));
      expect(classifyFeatures(a).code, classifyFeatures(b).code);
    });

    test('음수 결과는 정수 영역으로 보낸다', () {
      expect(classifyExpression('3-8').status, 'integer_domain');
    });

    test('지원하지 않는 식은 거절하고 eval 하지 않는다', () {
      expect(classifyExpression('2+3+4').status, 'rejected');
      expect(classifyExpression('(2+3)').status, 'rejected');
    });
  });

  group('분류', () {
    test('기존 37개 예시', () {
      for (final seed in naturalSeeds) {
        expect(classifyExpression(seed.example).code, seed.code, reason: seed.example);
      }
      expect(naturalSeeds, hasLength(37));
      expect(naturalSeeds.map((s) => s.code).toSet(), hasLength(37));
    });

    test('특수 규칙이 넓은 규칙보다 앞선다', () {
      expect(classifyExpression('13-8').code, 'nat_sub_teen_1d_b1');
      expect(classifyExpression('23*100').code, 'nat_mul_pow10');
      expect(classifyExpression('403-27').code, 'nat_sub_zero_chain');
    });

    test('초안은 켜기 전에는 기존 유형을 바꾸지 않는다', () {
      final zero = classifyExpression('37+0');
      expect(zero.code, 'nat_add_2d_1d_nc');
      expect(zero.candidates, contains('draft_add_zero'));
      expect(classifyExpression('37+0', activeDrafts: {'draft_add_zero'}).code, 'draft_add_zero');
      expect(classifyExpression('612/3').code, 'nat_div_3d_1d');
      expect(classifyExpression('3/7').code, isNull);
      expect(classifyExpression('235+4').code, isNull);
      expect(draftSeeds, hasLength(25));
    });
  });

  group('점수', () {
    const policy = ModelPolicy.initial;

    test('1500/1000ms 정확도 95', () {
      final speed = speedScore([1500 / 1000]);
      final fluency = fluencyScore(speed: speed, accuracy: 95, accuracyEligibleCount: 1, wSpeed: 1, wAccuracy: 1);
      expect(speed, closeTo(66.6667, 0.001));
      expect(fluency, closeTo(63.3333, 0.001));
    });

    test('기준보다 빠르면 100', () {
      expect(speedScore([800 / 1000]), 100);
      final fluency = fluencyScore(speed: 100, accuracy: 98, accuracyEligibleCount: 1, wSpeed: 1, wAccuracy: 1);
      expect(fluency, 98);
    });

    test('전부 오답이면 숙련도 0, 속도는 측정 전', () {
      final result = scoreAttempts([
        for (var i = 0; i < 10; i++)
          AttemptPoint(
            outcome: AttemptOutcome.incorrect,
            accuracyEligible: true,
            speedEligible: false,
            elapsedMs: 1000,
            referenceMs: 1000,
            fingerprint: 'item$i',
            atUtc: DateTime.utc(2026, 1, 1 + i),
          ),
      ], policy);
      expect(result.accuracy, 0);
      expect(result.speed, isNull);
      expect(result.fluency, 0);
    });

    test('시도가 없으면 측정 전이고 0점이 아니다', () {
      final result = scoreAttempts(const [], policy);
      expect(result.accuracy, isNull);
      expect(result.fluency, isNull);
    });

    test('오답을 속도 계산에서 빼도 정확도 분모는 유지된다', () {
      final result = scoreAttempts([
        _point(correct: false, elapsed: 1000),
        _point(correct: true, elapsed: 1000),
      ], policy);
      expect(result.accuracy, 50);
      expect(result.speed, 100);
    });

    test('유형별 점수를 밀리초로 섞지 않고 같은 가중으로 평균한다', () {
      expect(equalWeightMean([100, null, 50]), 75);
      expect(equalWeightMean([null, null]), isNull);
    });

    test('목표 등급과 속성 시간은 숙련도 공식에 들어가지 않는다', () {
      expect(policy.targetGradePercent, isNull);
      expect(policy.featureTimeAffectsFluency, isFalse);
      expect(policy.reasoningBasis, ReasoningBasis.alreadyWeighted);
      expect(policy.validate(), isNull);
    });
  });

  group('보정', () {
    test('type 7 분위수', () {
      const values = <double>[800, 900, 1000, 1100, 1200];
      expect(quantileType7(values, 0.30), 920);
      expect(median(values), 1000);
    });

    test('수축 추정', () {
      expect(shrink(t0: 1000, td: 800, k: 20, n: 10), closeTo(933.333, 0.001));
      expect(shrink(t0: 1000, td: 800, k: 20, n: 20), 900);
      expect(shrink(t0: 1000, td: 800, k: 20, n: 30), 880);
      expect(shrink(t0: 1000, td: 800, k: 20, n: 100), closeTo(833.333, 0.001));
    });

    test('인원별 판정', () {
      final none = calibrate(_request([]));
      expect(none.decision, ReferenceDecision.keepActive);
      expect(none.candidateMs, isNull);

      final five = calibrate(_request(_students(5, 800)));
      expect(five.decision, ReferenceDecision.keepActive);
      expect(five.candidateMs, isNull);
      expect(five.empiricalMs, 800);

      final ten = calibrate(_request(_students(10, 800)));
      expect(ten.candidateMs, closeTo(933.333, 0.001));
      expect(ten.decision, ReferenceDecision.needsApproval);

      final thirtySlow = calibrate(_request(_students(30, 800)));
      expect(thirtySlow.candidateMs, 880);
      expect(thirtySlow.changeFraction, closeTo(0.12, 0.001));
      expect(thirtySlow.decision, ReferenceDecision.needsApproval);

      final thirtyOk = calibrate(_request(_students(30, 950)));
      expect(thirtyOk.decision, ReferenceDecision.autoApply);

      final twentyNine = calibrate(_request(_students(29, 950)));
      expect(twentyNine.decision, ReferenceDecision.needsApproval);
    });

    test('적용된 기준을 최초값으로 다시 쓰지 않는다', () {
      final result = calibrate(_request(_students(30, 800), activeMs: 900));
      expect(result.candidateMs, 880);
    });

    test('한 학생은 대표값 하나다', () {
      final heavy = _students(1, 700, attempts: 10000);
      final light = _students(1, 900, attempts: 50);
      final result = calibrate(_request([...heavy, ...light]));
      expect(result.studentCount, 2);
      expect(result.mediansMs, [700, 900]);
    });

    test('98% 미만은 빠지고 속도 점수는 보지 않는다', () {
      final slowButAccurate = _students(1, 5000);
      final inaccurate = _studentWithWrongs('low');
      final result = calibrate(_request([...slowButAccurate, inaccurate]));
      expect(result.studentCount, 1);
      expect(result.reasons.join(' '), contains('정확도'));
    });

    test('같은 입력은 같은 구간', () {
      final a = calibrate(_request(_students(30, 800)));
      final b = calibrate(_request(_students(30, 800)));
      expect(a.candidateMs, b.candidateMs);
      expect(a.ciLowMs, b.ciLowMs);
      expect(a.ciHighMs, b.ciHighMs);
      expect(a.ciLowMs, isNotNull);
      expect(a.ciLowMs!, lessThanOrEqualTo(a.ciHighMs!));
    });
  });

  group('문항 비용', () {
    const policy = ModelPolicy.initial;

    test('이미 가중된 사고 점수는 5를 다시 곱하지 않는다', () {
      final live = problemCost(
        nodes: const [
          CostNode(id: 'op', kind: CostKind.operation, unitCost: 10, quantity: 1),
          CostNode(id: 'th', kind: CostKind.reasoning, unitCost: 40, quantity: 1),
        ],
        policy: policy,
      );
      expect(live.total, 50);
      expect(live.lambdaApplied, isFalse);
      final raw = problemCost(
        nodes: const [
          CostNode(id: 'op', kind: CostKind.operation, unitCost: 10, quantity: 1),
          CostNode(id: 'th', kind: CostKind.reasoning, unitCost: 8, quantity: 1),
        ],
        policy: policy,
        basis: ReasoningBasis.raw,
      );
      expect(raw.total, 50);
      expect(raw.lambdaApplied, isTrue);
    });

    test('50을 넘어도 자르지 않고, 0이면 비중은 없다', () {
      final over = problemCost(
        nodes: const [CostNode(id: 'op', kind: CostKind.operation, unitCost: 70, quantity: 1)],
        policy: policy,
      );
      expect(over.total, 70);
      final empty = problemCost(nodes: const [], policy: policy);
      expect(empty.total, 0);
      expect(empty.operationShare, isNull);
    });

    test('부모와 겹치는 자식은 한 번만 센다', () {
      final cost = problemCost(
        nodes: const [
          CostNode(id: 'parent', kind: CostKind.operation, unitCost: 1, quantity: 1),
          CostNode(id: 'child', kind: CostKind.operation, unitCost: 1, quantity: 1, parentId: 'parent'),
        ],
        policy: policy,
      );
      expect(cost.operation, 1);
      expect(cost.warnings, isNotEmpty);
    });

    test('비용 제안은 값을 돌려줄 뿐 적용하지 않는다', () {
      final hypothesis = proposeCost(
        anchorCost: 0.10,
        anchorReferenceMs: 1000,
        targetReferenceMs: 2000,
        sameProtocol: true,
        empirical: false,
      );
      expect(hypothesis.proposed, 0.20);
      expect(hypothesis.note, contains('가설'));
      expect(
        proposeCost(
          anchorCost: 0.10,
          anchorReferenceMs: 1000,
          targetReferenceMs: 2000,
          sameProtocol: false,
          empirical: true,
        ).proposed,
        isNull,
      );
    });
  });

  group('추정', () {
    test('297+8은 2.49초이고 시드 시간에 더하지 않는다', () {
      final estimate = estimateAdditionTime(_f('297+8'));
      expect(estimate.seconds, closeTo(2.49, 0.001));
      expect(estimate.terms.map((t) => t.seconds).reduce((a, b) => a + b), closeTo(2.49, 0.001));
      expect(estimate.reason, contains('더하지'));
    });

    test('덧셈이 아니면 추정하지 않는다', () {
      expect(estimateAdditionTime(_f('13-8')).defined, isFalse);
    });

    test('개인 곡선은 초기값에서 수렴값으로 내려간다', () {
      final curve = personalCurve(asymptoteSeconds: 1, initialSeconds: 8, k: 0.07, samples: 5, nMax: 40);
      expect(curve.first.seconds, 8);
      expect(curve.last.seconds, lessThan(8));
      expect(curve.last.seconds, greaterThan(1));
    });
  });
}

NaturalFeatures _f(String raw) {
  final parsed = parseNaturalExpression(raw);
  expect(parsed.ok, isTrue, reason: raw);
  return featuresOf(parsed.left!, parsed.right!, parsed.op!, parsed.display);
}

AttemptPoint _point({required bool correct, required int elapsed}) {
  return AttemptPoint(
    outcome: correct ? AttemptOutcome.correct : AttemptOutcome.incorrect,
    accuracyEligible: true,
    speedEligible: correct,
    elapsedMs: elapsed,
    referenceMs: 1000,
    fingerprint: 'a',
    atUtc: DateTime.utc(2026, 3, 1),
  );
}

CalibrationRequest _request(List<StudentWindow> students, {double? activeMs}) {
  return CalibrationRequest(
    students: students,
    cutoffUtc: DateTime.utc(2026, 6, 1),
    initialMs: 1000,
    activeMs: activeMs,
    policy: ModelPolicy.initial,
  );
}

List<StudentWindow> _students(int count, int ms, {int attempts = 50}) {
  return [for (var s = 0; s < count; s++) _one('s$s', ms, attempts: attempts)];
}

StudentWindow _one(String id, int ms, {int attempts = 50}) {
  return StudentWindow(
    studentId: id,
    attempts: [
      for (var i = 0; i < attempts; i++)
        AttemptPoint(
          outcome: AttemptOutcome.correct,
          accuracyEligible: true,
          speedEligible: true,
          elapsedMs: ms,
          referenceMs: 1000,
          fingerprint: 'item${i % 20}',
          atUtc: DateTime.utc(2026, 5, 1).add(Duration(hours: i)),
        ),
    ],
  );
}

StudentWindow _studentWithWrongs(String id) {
  return StudentWindow(
    studentId: id,
    attempts: [
      for (var i = 0; i < 50; i++)
        AttemptPoint(
          outcome: i < 2 ? AttemptOutcome.incorrect : AttemptOutcome.correct,
          accuracyEligible: true,
          speedEligible: i >= 2,
          elapsedMs: 1000,
          referenceMs: 1000,
          fingerprint: 'item${i % 20}',
          atUtc: DateTime.utc(2026, 5, 1 + (i % 3)),
        ),
    ],
  );
}
