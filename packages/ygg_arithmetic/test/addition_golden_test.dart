import 'package:test/test.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

void main() {
  test('명세 4.5의 덧셈 비용과 시간이 맞다', () {
    for (final row in _golden) {
      final parsed = parseAddition(row.expr);
      expect(parsed.ok, isTrue, reason: row.expr);
      final got = parsed.analysis!;
      expect(got.sum.toString(), row.sum, reason: row.expr);
      expect(got.features.derived['extra_pair'], row.ep, reason: '${row.expr} EP');
      expect(got.features.derived['solo_digit'], row.sd, reason: '${row.expr} SD');
      expect(got.features.derived['carry'], row.carry, reason: '${row.expr} carry');
      expect(got.features.derived['chain_link'], row.cl, reason: '${row.expr} CL');
      expect(got.features.derived['pair_size_delta'], row.psd, reason: '${row.expr} PSD');
      expect(got.features.derived['local_ten'], row.lt, reason: '${row.expr} LT');
      expect(got.features.derived['local_tie'], row.ti, reason: '${row.expr} TI');
      expect(got.features.derived['round_result'], row.rr, reason: '${row.expr} RR');
      expect(got.features.derived['identity'], row.id, reason: '${row.expr} ID');
      expect(got.costPoints, closeTo(row.cost, 0.0005), reason: '${row.expr} cost');
      expect(got.timeSeconds, closeTo(row.seconds, 0.0005), reason: '${row.expr} time');
      final costSum = got.terms.fold<int>(0, (s, t) => s + t.costMilli) + got.costFloorAdjustMilli;
      final timeSum = got.terms.fold<int>(0, (s, t) => s + t.timeMs) + got.timeFloorAdjustMs;
      expect(costSum, got.costMilli, reason: '${row.expr} cost parts');
      expect(timeSum, got.timeMs, reason: '${row.expr} time parts');
    }
  });

  test('378+245의 기여 합이 0.383점 3710ms다', () {
    final got = parseAddition('378 + 245').analysis!;
    expect(got.features.carryOuts, [1, 1, 0]);
    expect(got.costPoints, closeTo(0.383, 0.0005));
    expect(got.timeMs, 3710);
  });

  test('2+3과 3+2는 같은 비용이고 표시 순서는 남는다', () {
    final a = parseAddition('2+3').analysis!;
    final b = parseAddition('3+2').analysis!;
    expect(a.costMilli, b.costMilli);
    expect(a.timeMs, b.timeMs);
    expect(a.display, '2+3');
    expect(b.display, '3+2');
  });

  test('대표식 네 개의 합은 1.068점, 독립 시간은 10.680초다', () {
    const exprs = ['23+45', '37+63', '297+8', '78+57'];
    var cost = 0;
    var time = 0;
    for (final expr in exprs) {
      final got = parseAddition(expr).analysis!;
      cost += got.costMilli;
      time += got.timeMs;
    }
    expect(cost / 1000, closeTo(1.068, 0.0005));
    expect(time / 1000, closeTo(10.680, 0.0005));
  });

  test('음수, 소수, 세 항, 앞자리 0은 거절한다', () {
    expect(parseAddition('-3+1').ok, isFalse);
    expect(parseAddition('2.5+1').ok, isFalse);
    expect(parseAddition('1+2+3').ok, isFalse);
    expect(parseAddition('01+2').ok, isFalse);
    expect(parseAddition('0+0').ok, isTrue);
  });

  test('비용 계수를 바꿔도 시간은 그대로다', () {
    final changed = AdditionSeed.v1.replace('carry', costMilli: 90);
    final a = analyzeAddition(BigInt.from(7), BigInt.from(8));
    final b = analyzeAddition(BigInt.from(7), BigInt.from(8), seed: changed);
    expect(b.costMilli, isNot(a.costMilli));
    expect(b.timeMs, a.timeMs);
  });

  test('잔차 -200ms, 학생 20명, k=20이면 기본 시간이 100ms 줄어든다', () {
    final result = additionBiasCandidate(
      studentResidualMs: List<double>.filled(20, -200),
      priorK: 20,
      quantile: 0.30,
      seedBaseMs: 1000,
    );
    expect(result.deltaMs, -100);
    expect(result.candidateBaseMs, 900);
    final shifted = AdditionSeed.v1.replace('base', timeMs: result.candidateBaseMs!);
    final hard = analyzeAddition(BigInt.from(378), BigInt.from(245), seed: shifted);
    expect(hard.timeMs, 3610);
    expect(hard.costMilli, analyzeAddition(BigInt.from(378), BigInt.from(245)).costMilli);
  });

  test('적격 학생이 9명이면 후보가 없다', () {
    final result = additionBiasCandidate(
      studentResidualMs: List<double>.filled(9, -200),
      priorK: 20,
      quantile: 0.30,
      seedBaseMs: 1000,
    );
    expect(result.deltaMs, isNull);
  });

  test('기존 10개 대표식은 해당 프리셋에 맞는다', () {
    for (final preset in additionPresets) {
      final got = parseAddition(preset.example).analysis!;
      expect(preset.matches(got), isTrue, reason: preset.name);
    }
  });
}

class _Row {
  const _Row(this.expr, this.sum, this.ep, this.sd, this.carry, this.cl, this.psd, this.lt, this.ti, this.rr, this.id, this.cost, this.seconds);
  final String expr;
  final String sum;
  final int ep;
  final int sd;
  final int carry;
  final int cl;
  final int psd;
  final int lt;
  final int ti;
  final int rr;
  final int id;
  final double cost;
  final double seconds;
}

const _golden = <_Row>[
  _Row('2+3', '5', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.100, 1.000),
  _Row('1+2', '3', 0, 0, 0, 0, -2, 0, 0, 0, 0, 0.096, 0.960),
  _Row('4+5', '9', 0, 0, 0, 0, 4, 0, 0, 0, 0, 0.108, 1.080),
  _Row('9+1', '10', 0, 0, 1, 0, 5, 1, 0, 0, 0, 0.143, 1.530),
  _Row('7+8', '15', 0, 0, 1, 0, 10, 0, 0, 0, 0, 0.165, 1.730),
  _Row('8+8', '16', 0, 0, 1, 0, 11, 0, 1, 0, 0, 0.157, 1.670),
  _Row('0+0', '0', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0.050, 0.700),
  _Row('37+0', '37', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0.050, 0.960),
  _Row('23+4', '27', 0, 1, 0, 0, 2, 0, 0, 0, 0, 0.139, 1.480),
  _Row('27+8', '35', 0, 1, 1, 0, 10, 0, 0, 0, 0, 0.200, 1.990),
  _Row('98+7', '105', 0, 1, 2, 1, 10, 0, 0, 0, 0, 0.270, 2.670),
  _Row('23+45', '68', 1, 0, 0, 0, 4, 0, 0, 0, 0, 0.178, 1.870),
  _Row('27+48', '75', 1, 0, 1, 0, 11, 0, 0, 0, 0, 0.237, 2.360),
  _Row('78+57', '135', 1, 0, 2, 1, 17, 0, 0, 0, 0, 0.319, 3.160),
  _Row('234+53', '287', 1, 1, 0, 0, 5, 0, 0, 0, 0, 0.215, 2.330),
  _Row('687+586', '1273', 2, 0, 3, 2, 25, 0, 1, 0, 0, 0.465, 4.530),
  _Row('37+63', '100', 1, 0, 2, 1, 9, 1, 0, 1, 0, 0.266, 2.720),
  _Row('297+8', '305', 0, 2, 2, 1, 10, 0, 0, 0, 0, 0.305, 2.930),
  _Row('378+245', '623', 2, 0, 2, 1, 14, 0, 0, 0, 0, 0.383, 3.710),
  _Row('347+251', '598', 2, 0, 0, 0, 7, 0, 0, 0, 0, 0.254, 2.720),
  _Row('340+250', '590', 1, 0, 0, 0, 4, 0, 0, 0, 0, 0.178, 2.210),
  _Row('300+200', '500', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.100, 1.680),
  _Row('100+2', '102', 0, 2, 0, 0, 0, 0, 0, 0, 0, 0.170, 1.880),
  _Row('1717+2928', '4645', 3, 0, 2, 0, 17, 0, 0, 0, 0, 0.434, 4.410),
  _Row('1797+2128', '3925', 3, 0, 2, 1, 17, 0, 0, 0, 0, 0.459, 4.560),
  _Row('999+1', '1000', 0, 2, 3, 2, 5, 1, 0, 1, 0, 0.328, 3.230),
  _Row('99+99', '198', 1, 0, 2, 1, 26, 0, 2, 0, 0, 0.317, 3.180),
  _Row('37+99', '136', 1, 0, 2, 1, 18, 0, 0, 0, 0, 0.321, 3.180),
  _Row('101+909', '1010', 1, 0, 2, 0, 10, 2, 0, 0, 0, 0.256, 3.010),
  _Row('123+321', '444', 2, 0, 0, 0, -3, 0, 1, 0, 0, 0.224, 2.440),
  _Row('387+486', '873', 2, 0, 2, 1, 21, 0, 1, 0, 0, 0.387, 3.770),
  _Row('99+1', '100', 0, 1, 2, 1, 5, 1, 0, 1, 0, 0.223, 2.290),
  _Row('2+100', '102', 0, 2, 0, 0, 0, 0, 0, 0, 0, 0.170, 1.880),
  _Row('0+999999', '999999', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0.050, 2.000),
];
