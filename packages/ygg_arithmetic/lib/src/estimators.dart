import 'dart:math' as math;

import 'catalog.dart';
import 'features.dart';
import 'policy.dart';

class TimeTerm {
  const TimeTerm({required this.label, required this.seconds, required this.formula});

  final String label;
  final double seconds;
  final String formula;
}

class FeatureTimeEstimate {
  const FeatureTimeEstimate({
    required this.defined,
    required this.seconds,
    required this.terms,
    required this.reason,
  });

  final bool defined;
  final double? seconds;
  final List<TimeTerm> terms;
  final String reason;
}

/// 덧셈 가설식. 유형 시드 시간에 이 값을 더하지 않는다.
FeatureTimeEstimate estimateAdditionTime(
  NaturalFeatures features, {
  double base = 1,
  double digit = 0.12,
  double carry = 0.35,
  double chainExtra = 0.15,
  double resultDigit = 0.20,
}) {
  if (features.op != ArithmeticOp.add || features.carryCount == null || features.resultDigits == null) {
    return const FeatureTimeEstimate(
      defined: false,
      seconds: null,
      terms: [],
      reason: '이 연산군에는 가설 계수가 없습니다. 덧셈 식을 다른 연산에 적용하지 않습니다.',
    );
  }
  final digitTerm = digit * math.max(0, features.leftDigits + features.rightDigits - 2);
  final carryTerm = carry * features.carryCount!;
  final chainTerm = chainExtra * math.max(0, (features.carryChainLength ?? 0) - 1);
  final resultTerm = resultDigit * math.max(0, features.resultDigits! - 1);
  final total = base + digitTerm + carryTerm + chainTerm + resultTerm;
  return FeatureTimeEstimate(
    defined: true,
    seconds: total,
    terms: [
      TimeTerm(label: '기본', seconds: base, formula: base.toString()),
      TimeTerm(label: '자릿수', seconds: digitTerm, formula: '$digit×max(0, 자릿수 합−2)'),
      TimeTerm(label: '받아올림', seconds: carryTerm, formula: '$carry×${features.carryCount}'),
      TimeTerm(label: '연속 올림', seconds: chainTerm, formula: '$chainExtra×max(0, 연속−1)'),
      TimeTerm(label: '결과 자릿수', seconds: resultTerm, formula: '$resultDigit×max(0, 결과 자릿수−1)'),
    ],
    reason: '유형 시드 시간과 더하지 않는 별도 추정 경로입니다. 공식 숙련도에는 넣지 않습니다.',
  );
}

FeatureTimeEstimate estimateAdditionFromPolicy(NaturalFeatures features, ModelPolicy policy) {
  return estimateAdditionTime(
    features,
    base: policy.additionBaseSeconds,
    digit: policy.additionDigitSeconds,
    carry: policy.additionCarrySeconds,
    chainExtra: policy.additionChainExtraSeconds,
    resultDigit: policy.additionResultDigitSeconds,
  );
}

class CurvePoint {
  const CurvePoint({required this.n, required this.seconds});

  final double n;
  final double seconds;
}

/// T(n)=L+a·exp(−k·n). L은 개인 장기 예상이지 집단 기준이 아니다.
List<CurvePoint> personalCurve({
  required double asymptoteSeconds,
  required double initialSeconds,
  required double k,
  required int samples,
  required double nMax,
}) {
  if (asymptoteSeconds <= 0 || initialSeconds < asymptoteSeconds || k <= 0 || samples < 2 || nMax <= 0) {
    throw ArgumentError('수렴값은 0보다 크고, 초기 시간은 수렴값 이상이며, 학습 속도는 양수여야 합니다.');
  }
  final a = initialSeconds - asymptoteSeconds;
  return [
    for (var i = 0; i < samples; i++)
      CurvePoint(
        n: nMax * i / (samples - 1),
        seconds: asymptoteSeconds + a * math.exp(-k * nMax * i / (samples - 1)),
      ),
  ];
}

/// 시드 비용과 시드 시간의 산점도. 실측이 아니면 [hypothetical]이 참이다.
class CostTimePoint {
  const CostTimePoint({
    required this.code,
    required this.name,
    required this.cost,
    required this.referenceMs,
    required this.hypothetical,
  });

  final String code;
  final String name;
  final double cost;
  final int referenceMs;
  final bool hypothetical;
}

List<CostTimePoint> seedCostTimePoints() => [
      for (final seed in naturalSeeds)
        CostTimePoint(
          code: seed.code,
          name: seed.name,
          cost: seed.cost,
          referenceMs: seed.initialTimeMs,
          hypothetical: true,
        ),
    ];
