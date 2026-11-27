import 'package:flutter/material.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

import '../../think/think_style.dart';

class StudentScoreSimulator extends StatefulWidget {
  const StudentScoreSimulator({super.key, required this.policy});

  final ModelPolicy policy;

  @override
  State<StudentScoreSimulator> createState() => _StudentScoreSimulatorState();
}

class _StudentScoreSimulatorState extends State<StudentScoreSimulator> {
  final _ref = TextEditingController(text: '1.0');
  final _actual = TextEditingController(text: '1.5');
  final _accuracy = TextEditingController(text: '95');
  final _wSpeed = TextEditingController(text: '1');
  final _wAccuracy = TextEditingController(text: '1');

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _ref.dispose();
    _actual.dispose();
    _accuracy.dispose();
    _wSpeed.dispose();
    _wAccuracy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = _positive(_ref);
    final actual = _positive(_actual);
    final accuracy = _range(_accuracy, 0, 100);
    final wSpeed = _range(_wSpeed, 0.25, 4);
    final wAccuracy = _range(_wAccuracy, 0.25, 4);
    double? speed;
    double? fluency;
    if (ref != null && actual != null) speed = speedScore([actual / ref]);
    if (speed != null && accuracy != null && wSpeed != null && wAccuracy != null) {
      fluency = fluencyScore(
        speed: speed,
        accuracy: accuracy,
        accuracyEligibleCount: 1,
        wSpeed: wSpeed,
        wAccuracy: wAccuracy,
      );
    }
    final points = <_Pt>[
      if (ref != null)
        for (var i = 1; i <= 24; i++)
          _Pt(i / 8, speedScore([(i / 8) / ref]) ?? 0),
    ];
    return _SimCard(
      title: '학생 연산 점수',
      virtual: true,
      note: '숙련 판정 예시입니다. 표본 수·측정일·문항 수는 확인하지 않습니다. 슬라이더는 운영 정책을 바꾸지 않습니다.',
      fields: [
        _NumField(controller: _ref, label: '기준 시간(초)', onChanged: _refresh),
        _NumField(controller: _actual, label: '실제 시간(초)', onChanged: _refresh),
        _NumField(controller: _accuracy, label: '정확도(%)', onChanged: _refresh),
        _NumField(controller: _wSpeed, label: '속도 지수', onChanged: _refresh),
        _NumField(controller: _wAccuracy, label: '정확도 지수', onChanged: _refresh),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('속도 ${_fmt(speed)} · 정확도 ${_fmt(accuracy)} · 숙련도 ${_fmt(fluency)}', key: const Key('sim-speed'), style: _valueStyle),
          const SizedBox(height: 4),
          Text('S = 100 × min(1, 기준/실제)의 중앙값. 이 예시는 시도 하나라 그 비율 그대로입니다.', style: _hintStyle),
          const SizedBox(height: 8),
          Text('운영 숙련 문턱은 정확도 ${widget.policy.masteryAccuracyPct}% · 속도 ${widget.policy.masterySpeed}점입니다. 이 칸의 지수를 바꿔도 그 문턱은 그대로입니다.', style: _hintStyle),
          const SizedBox(height: 12),
          const Text('가로: 실제 시간(초)  세로: 속도 점수', style: _hintStyle),
          const SizedBox(height: 4),
          _SeriesChart(points: points, markerX: actual, yMax: 100, xMax: 3),
        ],
      ),
    );
  }
}

class CalibrationSimulator extends StatefulWidget {
  const CalibrationSimulator({super.key});

  @override
  State<CalibrationSimulator> createState() => _CalibrationSimulatorState();
}

class _CalibrationSimulatorState extends State<CalibrationSimulator> {
  final _t0 = TextEditingController(text: '1000');
  final _td = TextEditingController(text: '800');
  final _k = TextEditingController(text: '20');
  final _n = TextEditingController(text: '30');
  final _active = TextEditingController(text: '1000');
  final _samples = TextEditingController(text: '800, 900, 1000, 1100, 1200');
  final _q = TextEditingController(text: '0.30');
  bool _fromSamples = false;

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _t0.dispose();
    _td.dispose();
    _k.dispose();
    _n.dispose();
    _active.dispose();
    _samples.dispose();
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t0 = _positive(_t0);
    final k = _positive(_k);
    final n = int.tryParse(_n.text.trim());
    final active = _positive(_active);
    final q = _range(_q, 0.01, 0.99);
    double? td = _positive(_td);
    String qNote = 'Td를 직접 넣는 모드입니다. q를 바꿔도 Td는 움직이지 않습니다.';
    if (_fromSamples && q != null) {
      final samples = _sampleList(_samples.text);
      if (samples != null) {
        td = quantileType7(samples, q);
        qNote = '대표값 목록으로 Td를 다시 계산했습니다. q=${q.toStringAsFixed(2)} → Td ${_fmt(td)}ms.';
      } else {
        td = null;
        qNote = '대표값은 쉼표로 구분한 양수(ms)여야 합니다.';
      }
    }
    CalibrationResult? result;
    if (t0 != null && k != null && n != null && n >= 0 && td != null && active != null) {
      final policy = ModelPolicy.initial.copyWith(priorStrengthK: k, empiricalQuantile: q ?? 0.3);
      result = calibrate(CalibrationRequest(
        students: n == 0 ? const [] : uniformStudents(count: n, elapsedMs: td.round()),
        cutoffUtc: DateTime.utc(2026, 6, 1),
        initialMs: t0,
        activeMs: active,
        policy: policy,
      ));
    }
    final curve = <_Pt>[
      if (t0 != null && k != null && td != null)
        for (final count in [0, 5, 10, 20, 30, 50, 100, 200])
          if (count == 0) _Pt(0, t0) else _Pt(count.toDouble(), shrink(t0: t0, td: td, k: k, n: count)),
    ];
    return _SimCard(
      title: '기준 시간 자동 보정',
      virtual: true,
      note: '가상 학생입니다. 보정 실행 기록에 저장하지 않고, 연산 비용도 바꾸지 않습니다.',
      fields: [
        _NumField(controller: _t0, label: '최초 T0(ms)', onChanged: _refresh),
        _NumField(controller: _td, label: '경험 Td(ms)', enabled: !_fromSamples, onChanged: _refresh),
        _NumField(controller: _k, label: '강도 k', onChanged: _refresh),
        _NumField(controller: _n, label: '적격 학생 수', onChanged: _refresh),
        _NumField(controller: _active, label: '활성 기준(ms)', onChanged: _refresh),
        _NumField(controller: _q, label: '분위수 q', onChanged: _refresh),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: () => setState(() => _fromSamples = !_fromSamples),
            child: Text(_fromSamples ? 'Td 직접 입력으로 돌아가기' : '대표값 목록으로 q 실험'),
          ),
          if (_fromSamples) _NumField(controller: _samples, label: '대표값 ms', onChanged: () => setState(() {})),
          Text(qNote, style: _hintStyle),
          const SizedBox(height: 8),
          Text(
            result == null
                ? '입력을 확인해 주세요.'
                : '후보 ${_fmt(result.candidateMs)}ms · 반영 ${_fmt(result.dataWeight == null ? null : result.dataWeight! * 100)}% · ${_decisionLabel(result.decision)}',
            key: const Key('sim-candidate'),
            style: _valueStyle,
          ),
          if (result != null && result.changeFraction != null)
            Text('활성 기준 대비 ${(result.changeFraction! * 100).toStringAsFixed(1)}%', style: _hintStyle),
          if (result != null)
            for (final reason in result.reasons.take(3)) Text(reason, style: _hintStyle),
          const SizedBox(height: 8),
          const Text('가로: 적격 학생 수  세로: 후보 시간(ms)', style: _hintStyle),
          const SizedBox(height: 4),
          _SeriesChart(points: curve, markerX: n?.toDouble(), yMax: (t0 ?? 1000) * 1.2, xMax: 200),
        ],
      ),
    );
  }
}

class ProblemCostSimulator extends StatefulWidget {
  const ProblemCostSimulator({super.key, required this.policy});

  final ModelPolicy policy;

  @override
  State<ProblemCostSimulator> createState() => _ProblemCostSimulatorState();
}

class _ProblemCostSimulatorState extends State<ProblemCostSimulator> {
  final _operation = TextEditingController(text: '10');
  final _reasoning = TextEditingController(text: '40');
  bool _raw = false;

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _operation.dispose();
    _reasoning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final operation = _nonNegative(_operation);
    final reasoning = _nonNegative(_reasoning);
    ProblemCost? cost;
    if (operation != null && reasoning != null) {
      cost = problemCost(
        nodes: [
          CostNode(id: 'op', kind: CostKind.operation, unitCost: operation, quantity: 1),
          CostNode(id: 'th', kind: CostKind.reasoning, unitCost: reasoning, quantity: 1),
        ],
        policy: widget.policy,
        basis: _raw ? ReasoningBasis.raw : ReasoningBasis.alreadyWeighted,
      );
    }
    return _SimCard(
      title: '문항 비용',
      virtual: true,
      note: '운영 기본은 이미 가중된 사고 점수입니다. 5를 곱하는 칸은 연구 예시이고 저장된 문항 점수를 다시 계산하지 않습니다.',
      fields: [
        _NumField(controller: _operation, label: '연산 비용 C', onChanged: _refresh),
        _NumField(controller: _reasoning, label: _raw ? '가중 전 사고 R' : '이미 가중된 사고', onChanged: _refresh),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: () => setState(() {
              _raw = !_raw;
              _reasoning.text = _raw ? '8' : '40';
            }),
            child: Text(_raw ? '운영 방식(이미 가중)으로 보기' : '가설 예시(가중 전 ×5) 보기'),
          ),
          Text(
            cost == null ? '입력을 확인해 주세요.' : '종합 ${cost.total.toStringAsFixed(1)}점 · 앵커와 차이 ${cost.anchorGap.toStringAsFixed(1)}',
            key: const Key('sim-cost'),
            style: _valueStyle,
          ),
          Text(
            cost == null
                ? ''
                : '연산 비중 ${_share(cost.operationShare)} · 사고 비중 ${_share(cost.reasoningShare)}',
            style: _hintStyle,
          ),
          if (cost != null)
            for (final warning in cost.warnings) Text(warning, style: _hintStyle),
          const SizedBox(height: 8),
          if (cost != null && cost.total > 0)
            _ShareBar(operation: cost.operation, reasoning: cost.reasoningUsed),
        ],
      ),
    );
  }
}

class FeatureTimeSimulator extends StatefulWidget {
  const FeatureTimeSimulator({super.key});

  @override
  State<FeatureTimeSimulator> createState() => _FeatureTimeSimulatorState();
}

class _FeatureTimeSimulatorState extends State<FeatureTimeSimulator> {
  final _expr = TextEditingController(text: '297+8');
  String _shown = '';

  @override
  void initState() {
    super.initState();
    _shown = _expr.text;
  }

  @override
  void dispose() {
    _expr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = parseNaturalExpression(_shown);
    final features = parsed.ok ? featuresOf(parsed.left!, parsed.right!, parsed.op!, parsed.display) : null;
    final estimate = features == null ? null : estimateAdditionTime(features);
    final classification = features == null ? null : classifyFeatures(features);
    final seed = classification?.code == null ? null : seedByCode(classification!.code!);
    return _SimCard(
      title: '속성으로 가늠한 시간',
      virtual: true,
      note: '덧셈 가설식입니다. 유형 시드 시간에 이 값을 더하지 않고, 학생 숙련도에도 넣지 않습니다.',
      fields: [
        _NumField(
          controller: _expr,
          label: '식',
          onSubmitted: () => setState(() => _shown = _expr.text),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(onPressed: () => setState(() => _shown = _expr.text), child: const Text('이 식으로 계산')),
          if (!parsed.ok) Text(parsed.message, style: const TextStyle(color: kThinkError, fontSize: 12)),
          if (estimate != null && estimate.defined) ...[
            Text('추정 ${estimate.seconds!.toStringAsFixed(2)}초', key: const Key('sim-feature-time'), style: _valueStyle),
            Text(estimate.reason, style: _hintStyle),
            for (final term in estimate.terms)
              Text('${term.label} ${term.seconds.toStringAsFixed(2)}초 · ${term.formula}', style: _hintStyle),
            Text(
              seed == null ? '활성 유형이 없습니다. 시드 시간과 비교하지 않습니다.' : '유형 시드 ${(seed.initialTimeMs / 1000).toStringAsFixed(2)}초와 별개입니다.',
              style: _hintStyle,
            ),
          ],
          if (estimate != null && !estimate.defined) Text(estimate.reason, style: _hintStyle),
          if (classification != null)
            Text(
              '분류 ${classification.code ?? '미분류'} · 초안 후보 ${classification.candidates.isEmpty ? '없음' : classification.candidates.join(', ')}',
              style: _hintStyle,
            ),
        ],
      ),
    );
  }
}

class PersonalCurveSimulator extends StatefulWidget {
  const PersonalCurveSimulator({super.key});

  @override
  State<PersonalCurveSimulator> createState() => _PersonalCurveSimulatorState();
}

class _PersonalCurveSimulatorState extends State<PersonalCurveSimulator> {
  final _initial = TextEditingController(text: '8');
  final _limit = TextEditingController(text: '1');
  final _k = TextEditingController(text: '0.07');
  double _n = 20;

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _initial.dispose();
    _limit.dispose();
    _k.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = _positive(_initial);
    final limit = _positive(_limit);
    final k = _positive(_k);
    List<CurvePoint>? curve;
    String? error;
    if (initial != null && limit != null && k != null) {
      if (initial < limit) {
        error = '초기 시간은 수렴값 이상이어야 합니다.';
      } else {
        curve = personalCurve(asymptoteSeconds: limit, initialSeconds: initial, k: k, samples: 25, nMax: 80);
      }
    }
    final at = curve?.reduce((a, b) => (a.n - _n).abs() < (b.n - _n).abs() ? a : b);
    return _SimCard(
      title: '개인 학습 곡선',
      virtual: true,
      note: '가상 곡선입니다. 실제 학생에게 식을 맞추지 않으며, 집단 기준 시간에 반영하지 않습니다.',
      fields: [
        _NumField(controller: _initial, label: '초기 시간(초)', onChanged: _refresh),
        _NumField(controller: _limit, label: '개인 수렴값 L(초)', onChanged: _refresh),
        _NumField(controller: _k, label: '학습 속도 k', onChanged: _refresh),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error ?? (at == null ? '입력을 확인해 주세요.' : '연습 ${_n.round()}회에서 ${at.seconds.toStringAsFixed(2)}초'), style: _valueStyle),
          Slider(
            value: _n,
            min: 0,
            max: 80,
            activeColor: kThinkAccent,
            onChanged: (v) => setState(() => _n = v),
          ),
          const Text('가로: 누적 연습  세로: 시간(초). 가로 점선은 개인 수렴값입니다.', style: _hintStyle),
          const SizedBox(height: 4),
          if (curve != null)
            _SeriesChart(
              points: [for (final p in curve) _Pt(p.n, p.seconds)],
              markerX: _n,
              yMax: initial ?? 8,
              xMax: 80,
            ),
        ],
      ),
    );
  }
}

class CostRelationSimulator extends StatelessWidget {
  const CostRelationSimulator({super.key});

  @override
  Widget build(BuildContext context) {
    final scratch = [for (final seed in naturalSeeds) if (seed.protocolCode == 'scratch_integer_v1') seed];
    final anchor = scratch.firstWhere((s) => s.code == 'nat_add_2d_1d_nc');
    final target = scratch.firstWhere((s) => s.code == 'nat_mul_3d_3d');
    final proposal = proposeCost(
      anchorCost: anchor.cost,
      anchorReferenceMs: anchor.initialTimeMs.toDouble(),
      targetReferenceMs: target.initialTimeMs.toDouble(),
      sameProtocol: true,
      empirical: false,
    );
    final points = [for (final seed in scratch) _Pt(seed.cost, seed.initialTimeMs.toDouble())];
    return _SimCard(
      title: '연산 비용과 기준 시간',
      virtual: true,
      note: '점은 37개 자연수 유형의 시드 비용과 가설 시간입니다. 실측이 아니고, 운영 비용을 바꾸지 않습니다. 다른 프로토콜을 한 줄로 섞지 않습니다.',
      fields: const [],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('점은 메모를 허용하는 정수 답 프로토콜의 시드만 그렸습니다. 기초 암산은 넣지 않았습니다.', style: _hintStyle),
          const SizedBox(height: 8),
          const Text('가로: 시드 비용  세로: 가설 기준 시간(ms)', style: _hintStyle),
          const SizedBox(height: 4),
          _SeriesChart(points: points, yMax: 26000, xMax: 1.6, dots: true),
          const SizedBox(height: 8),
          Text('${target.name} 제안 ${proposal.proposed?.toStringAsFixed(2) ?? '없음'}. ${proposal.note}', style: _hintStyle),
        ],
      ),
    );
  }
}

class _SeriesChart extends StatelessWidget {
  const _SeriesChart({
    required this.points,
    required this.yMax,
    required this.xMax,
    this.markerX,
    this.dots = false,
  });

  final List<_Pt> points;
  final double yMax;
  final double xMax;
  final double? markerX;
  final bool dots;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      width: double.infinity,
      child: CustomPaint(
        painter: _SeriesPainter(points: points, yMax: yMax, xMax: xMax, markerX: markerX, dots: dots),
      ),
    );
  }
}

class _SeriesPainter extends CustomPainter {
  _SeriesPainter({
    required this.points,
    required this.yMax,
    required this.xMax,
    required this.markerX,
    required this.dots,
  });

  final List<_Pt> points;
  final double yMax;
  final double xMax;
  final double? markerX;
  final bool dots;

  @override
  void paint(Canvas canvas, Size size) {
    final axis = Paint()
      ..color = kThinkBorder
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1), axis);
    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), axis);
    if (points.isEmpty || yMax <= 0 || xMax <= 0) return;
    final paint = Paint()
      ..color = kThinkAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final dx = (points[i].x / xMax).clamp(0, 1) * size.width;
      final dy = size.height - (points[i].y / yMax).clamp(0, 1) * size.height;
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
      if (dots) {
        canvas.drawCircle(Offset(dx, dy), 3, Paint()..color = kThinkLink);
      }
    }
    if (!dots) canvas.drawPath(path, paint);
    final mark = markerX;
    if (mark != null) {
      final x = (mark / xMax).clamp(0, 1) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = kThinkSub);
    }
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter oldDelegate) => true;
}

class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.operation, required this.reasoning});

  final double operation;
  final double reasoning;

  @override
  Widget build(BuildContext context) {
    final total = operation + reasoning;
    if (total <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 16,
        child: Row(
          children: [
            Expanded(flex: (operation / total * 1000).round().clamp(1, 1000), child: const ColoredBox(color: kThinkAccent)),
            Expanded(flex: (reasoning / total * 1000).round().clamp(1, 1000), child: const ColoredBox(color: kThinkLink)),
          ],
        ),
      ),
    );
  }
}

class _SimCard extends StatelessWidget {
  const _SimCard({
    required this.title,
    required this.virtual,
    required this.note,
    required this.fields,
    required this.body,
  });

  final String title;
  final bool virtual;
  final String note;
  final List<Widget> fields;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              if (virtual) const ThinkBadge('가상', color: kThinkLink),
            ],
          ),
          const SizedBox(height: 4),
          Text(note, style: _hintStyle),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: fields),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}

class _NumField extends StatelessWidget {
  const _NumField({required this.controller, required this.label, this.enabled = true, this.onSubmitted, this.onChanged});

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        enabled: enabled,
        style: const TextStyle(color: kThinkText, fontSize: 13),
        decoration: thinkInputDecoration(label: label),
        onChanged: (_) {
          if (onChanged != null) {
            onChanged!.call();
          } else {
            onSubmitted?.call();
          }
        },
        onSubmitted: (_) => onSubmitted?.call(),
      ),
    );
  }
}

class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}

const _valueStyle = TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700);
const _hintStyle = TextStyle(color: kThinkSub, fontSize: 12, height: 1.4);

double? _positive(TextEditingController c) {
  final v = double.tryParse(c.text.trim());
  if (v == null || v <= 0 || v.isNaN || v.isInfinite) return null;
  return v;
}

double? _nonNegative(TextEditingController c) {
  final v = double.tryParse(c.text.trim());
  if (v == null || v < 0 || v.isNaN || v.isInfinite) return null;
  return v;
}

double? _range(TextEditingController c, double min, double max) {
  final v = double.tryParse(c.text.trim());
  if (v == null || v < min || v > max) return null;
  return v;
}

List<double>? _sampleList(String raw) {
  final parts = raw.split(RegExp(r'[,\s]+')).where((p) => p.isNotEmpty);
  final values = <double>[];
  for (final part in parts) {
    final v = double.tryParse(part);
    if (v == null || v <= 0) return null;
    values.add(v);
  }
  if (values.isEmpty) return null;
  return values;
}

String _fmt(double? value) => value == null ? '측정 전' : value.toStringAsFixed(1);

String _share(double? value) => value == null ? '—' : '${(value * 100).toStringAsFixed(0)}%';

String _decisionLabel(ReferenceDecision decision) => switch (decision) {
      ReferenceDecision.keepActive => '활성 기준 유지',
      ReferenceDecision.candidateOnly => '후보만 기록',
      ReferenceDecision.needsApproval => '승인 필요',
      ReferenceDecision.autoApply => '자동 적용 가능',
    };
