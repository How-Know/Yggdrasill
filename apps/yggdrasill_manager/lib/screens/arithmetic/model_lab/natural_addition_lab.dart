import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

import '../../think/think_style.dart';

/// 자연수 덧셈 한 모델. 다른 연산 목록은 이 화면 밖에 둔다.
class NaturalAdditionLab extends StatefulWidget {
  const NaturalAdditionLab({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<NaturalAdditionLab> createState() => _NaturalAdditionLabState();
}

class _NaturalAdditionLabState extends State<NaturalAdditionLab> {
  final _expr = TextEditingController(text: '378+245');
  final _answer = TextEditingController();
  AdditionSeed _draft = AdditionSeed.v3;
  int _section = 0;
  String _shown = '378+245';
  int _heatMode = 0;
  final _items = <_QuizItem>[];
  int _itemsIndex = -1;
  final _clock = Stopwatch();
  final _n = TextEditingController(text: '20');
  final _residual = TextEditingController(text: '-200');
  final _k = TextEditingController(text: '20');

  static const _sections = ['분석', '계수', '히트맵', '프리셋', '평가', '보정', '출제'];
  static const _quotaCases = <(String, List<int>)>[
    ('균등', [1, 1, 1, 1, 1]),
    ('2·3·4만', [0, 1, 1, 1, 0]),
    ('어려운 쪽', [0, 1, 2, 1, 0]),
  ];
  int _quotaCase = 0;
  TrainingResult? _bandSample;

  @override
  void dispose() {
    _expr.dispose();
    _answer.dispose();
    _n.dispose();
    _residual.dispose();
    _k.dispose();
    super.dispose();
  }

  void _applyExpr() => setState(() => _shown = _expr.text);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kThinkBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '연산 목록',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back, color: kThinkSub, size: 18),
                ),
                const Expanded(
                  child: Text('자연수 덧셈', style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
                ),
                const ThinkBadge('초기 추정', color: kThinkLink),
              ],
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (var i = 0; i < _sections.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ThinkToggleChip(
                      label: _sections[i],
                      icon: Icons.circle_outlined,
                      selected: _section == i,
                      onChanged: (_) => setState(() => _section = i),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: kThinkBorder, height: 12),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                if (_section == 0) _analyzer(),
                if (_section == 1) _coeffs(),
                if (_section == 2) _heatmap(),
                if (_section == 3) _presets(),
                if (_section == 4) _quizPane(),
                if (_section == 5) _bias(),
                if (_section == 6) _policy(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _analyzer() {
    if ('+'.allMatches(_shown).length > 1) return _multi();
    final parsed = parseAddition(_shown, seed: _draft);
    final got = parsed.analysis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('addition-expression'),
          controller: _expr,
          style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w700),
          decoration: thinkInputDecoration(label: '식'),
          onSubmitted: (_) => _applyExpr(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: _applyExpr, child: const Text('계산')),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final sample in ['2+3', '7+8', '37+63', '378+245', '300+200', '27+38+15+42'])
              TextButton(
                onPressed: () {
                  _expr.text = sample;
                  _applyExpr();
                },
                child: Text(sample),
              ),
          ],
        ),
        if (!parsed.ok) Text(parsed.message, style: const TextStyle(color: kThinkError, fontSize: 13)),
        if (got != null) ...[
          Text(
            '${got.display}=${got.sum}  ·  ${got.costPoints.toStringAsFixed(3)}점  ·  ${got.timeSeconds.toStringAsFixed(3)}초',
            key: const Key('addition-result'),
            style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text('비용은 표준 세로셈 작업량입니다. 시간은 표준 절차 추정이고, 자유 풀이 실측 기준은 아직 없습니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          Text('받아올림 ${got.features.carryOuts.join(', ')} (일의 자리부터) · 연쇄 ${got.features.carryChainLinks}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          for (final term in got.terms)
            if (term.costMilli != 0 || term.timeMs != 0)
              Text(
                '${additionTermLabels[term.key] ?? term.key} ×${term.x}  ${ _milli(term.costMilli)}점  ${term.timeMs}ms',
                style: const TextStyle(color: kThinkText, fontSize: 12),
              ),
          if (got.costFloorAdjustMilli != 0 || got.timeFloorAdjustMs != 0)
            Text('하한 보정 ${_milli(got.costFloorAdjustMilli)}점 ${got.timeFloorAdjustMs}ms', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          Text(
            '맞는 예전 유형: ${matchingPresets(got).map((p) => p.name).join(', ')}',
            style: const TextStyle(color: kThinkSub, fontSize: 12),
          ),
          if (math.max(got.features.operandADigits, got.features.operandBDigits) >= 4)
            const Text('네 자리 이상은 실측이 없어 외삽 추정입니다.', style: TextStyle(color: kThinkSub, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _multi() {
    final many = parseAdditionList(_shown, seed: _draft);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('addition-expression'),
          controller: _expr,
          style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w700),
          decoration: thinkInputDecoration(label: '식'),
          onSubmitted: (_) => _applyExpr(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: _applyExpr, child: const Text('계산')),
        ),
        if (many == null)
          const Text('자연수 덧셈만 읽습니다. 예: 27+38+15+42', style: TextStyle(color: kThinkError, fontSize: 13))
        else ...[
          Text(
            '${many.display}=${many.sum}  ·  ${_milli(many.costMilli)}점  ·  ${(many.timeMs / 1000).toStringAsFixed(3)}초',
            key: const Key('addition-result'),
            style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text('세 수 이상은 왼쪽부터 두 수씩 더합니다. 비용은 단계 합이고, 입력·출력 시간은 전체 숫자와 최종 답에 한 번만 더합니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          for (final step in many.steps)
            Text(
              '${step.index + 1}단계 ${step.analysis.display}=${step.analysis.sum} · 받아올림 ${step.analysis.features.carryCount} · ${_milli(step.analysis.costMilli)}점',
              style: const TextStyle(color: kThinkText, fontSize: 12),
            ),
        ],
      ],
    );
  }

  Widget _coeffs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('숫자를 고치면 이 화면의 분석·히트맵·프리셋이 바로 바뀝니다. 발행 전에는 운영 값이 아닙니다. 비용과 시간은 따로 움직입니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        for (final coeff in _draft.coeffs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(width: 92, child: Text(additionTermLabels[coeff.key] ?? coeff.key, style: const TextStyle(color: kThinkText, fontSize: 12))),
                _coeffField(coeff.key, coeff.costMilli, (v) => setState(() => _draft = _draft.replace(coeff.key, costMilli: v)), '점×1000'),
                const SizedBox(width: 8),
                _coeffField(coeff.key, coeff.timeMs, (v) => setState(() => _draft = _draft.replace(coeff.key, timeMs: v)), 'ms'),
              ],
            ),
          ),
        TextButton(
          onPressed: () => setState(() => _draft = AdditionSeed.v3),
          child: const Text('시드 v3으로 되돌리기'),
        ),
        const Text('기본 0.100점은 2+3의 출발점입니다. 받아올림은 전달마다, 연쇄는 그 위의 의존만 더합니다. 10 보수와 같은 숫자는 할인 가설입니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
      ],
    );
  }

  Widget _coeffField(String featureKey, int value, ValueChanged<int> onChanged, String unit) {
    return SizedBox(
      width: 88,
      child: TextFormField(
        key: ValueKey('$featureKey-$unit'),
        initialValue: '$value',
        style: const TextStyle(color: kThinkText, fontSize: 13),
        decoration: thinkInputDecoration(label: unit),
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'-?\d*'))],
        onChanged: (text) {
          final parsed = int.tryParse(text);
          if (parsed != null) onChanged(parsed);
        },
      ),
    );
  }

  Widget _heatmap() {
    final labels = ['비용', '시간'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('0부터 9까지 100칸을 같은 식으로 계산합니다. 칸을 누르면 분석으로 넘어갑니다. 색 옆의 숫자는 비용(점) 또는 시간(초)입니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < labels.length; i++)
              ThinkToggleChip(
                label: labels[i],
                icon: Icons.grid_on,
                selected: _heatMode == i,
                onChanged: (_) => setState(() => _heatMode = i),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var a = 0; a <= 9; a++)
          Row(
            children: [
              for (var b = 0; b <= 9; b++)
                Expanded(child: _cell(a, b)),
            ],
          ),
      ],
    );
  }

  Widget _cell(int a, int b) {
    final got = analyzeAddition(BigInt.from(a), BigInt.from(b), seed: _draft);
    final text = _heatMode == 0 ? got.costPoints.toStringAsFixed(2) : got.timeSeconds.toStringAsFixed(1);
    final tone = _heatMode == 0 ? (got.costMilli / 200).clamp(0.15, 0.9) : (got.timeMs / 2500).clamp(0.15, 0.9);
    return Padding(
      padding: const EdgeInsets.all(1),
      child: Material(
        color: kThinkAccent.withValues(alpha: tone),
        child: InkWell(
          onTap: () {
            _expr.text = '$a+$b';
            setState(() {
              _shown = '$a+$b';
              _section = 0;
            });
          },
          child: SizedBox(
            height: 28,
            child: Center(child: Text(text, style: const TextStyle(color: kThinkText, fontSize: 8))),
          ),
        ),
      ),
    );
  }

  Widget _presets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('예전 10개 유형은 검색·출제용 프리셋입니다. 비용의 기준은 아닙니다. 오른쪽이 대표식을 지금 모델로 계산한 값입니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        for (final preset in additionPresets)
          _presetLine(preset),
      ],
    );
  }

  Widget _presetLine(AdditionPreset preset) {
    final got = parseAddition(preset.example, seed: _draft).analysis!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '${preset.name}\n${preset.example}  이전 ${preset.legacyCost.toStringAsFixed(2)}점/${preset.legacySeconds.toStringAsFixed(1)}초  →  ${got.costPoints.toStringAsFixed(3)}점/${got.timeSeconds.toStringAsFixed(3)}초',
        style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.35),
      ),
    );
  }

  Widget _quizPane() {
    if (_itemsIndex < 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('관리자가 이 화면에서 덧셈을 풀어 시간과 맞힌 비율을 봅니다. 이 연습은 학생 통계에 넣지 않습니다. 학생 앱 측정은 아직 연결하지 않았습니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: _startQuiz, style: thinkPrimaryButton(), child: const Text('8문항 시작')),
        ],
      );
    }
    if (_itemsIndex >= _items.length) {
      final ratios = [
        for (final item in _items)
          if (item.correct && item.elapsedMs > 0) item.elapsedMs / item.referenceMs,
      ];
      final correct = _items.where((e) => e.correct).length;
      final speed = speedScore(ratios);
      final accuracy = 100 * correct / _items.length;
      final fluency = fluencyScore(
        speed: speed,
        accuracy: accuracy,
        accuracyEligibleCount: _items.length,
        wSpeed: 1,
        wAccuracy: 1,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('맞힌 $correct/${_items.length}  ·  속도 ${_num(speed)}  ·  숙련 ${_num(fluency)}', style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
          const Text('8문항이라 숙련 판정은 하지 않습니다. 속도는 문항마다 기준 시간으로 나눈 비율의 중앙값입니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          TextButton(onPressed: () => setState(() => _itemsIndex = -1), child: const Text('다시')),
        ],
      );
    }
    final item = _items[_itemsIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_itemsIndex + 1}/${_items.length}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        Text(item.expr, key: const Key('quiz-expr'), style: const TextStyle(color: kThinkText, fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(
          controller: _answer,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: kThinkText, fontSize: 18),
          decoration: thinkInputDecoration(label: '답'),
          onSubmitted: (_) => _submitQuiz(),
        ),
        TextButton(onPressed: _submitQuiz, child: const Text('제출')),
      ],
    );
  }

  void _startQuiz() {
    final random = math.Random(20261126);
    final items = <_QuizItem>[];
    while (items.length < 8) {
      final a = random.nextInt(80) + 10;
      final b = random.nextInt(9) + 1;
      final analysis = analyzeAddition(BigInt.from(a), BigInt.from(b), seed: _draft);
      items.add(_QuizItem(analysis.display, analysis.sum, analysis.timeMs));
    }
    _answer.clear();
    _clock
      ..reset()
      ..start();
    setState(() {
      _items
        ..clear()
        ..addAll(items);
      _itemsIndex = 0;
    });
  }

  void _submitQuiz() {
    final item = _items[_itemsIndex];
    final elapsed = _clock.elapsedMilliseconds;
    final given = BigInt.tryParse(_answer.text.trim());
    item
      ..elapsedMs = elapsed
      ..correct = given == item.sum;
    _answer.clear();
    _clock
      ..reset()
      ..start();
    setState(() => _itemsIndex += 1);
  }

  Widget _policy() {
    _bandSample ??= generateAdditionSet(const TrainingRequest(
      digits: [1, 1],
      carry: CarryFilter.mixed,
      count: 10,
      bands: [true, true, true, true, true],
      weights: [1, 1, 1, 1, 1],
      seed: 1,
    ));
    final sample = _bandSample!;
    final weights = _quotaCases[_quotaCase].$2;
    final quotas = hamiltonQuotas(30, weights);
    final standard = analyzeOperands([BigInt.from(378), BigInt.from(245)], seed: _draft).timeMs;
    final efficiency = efficiencyIndex([standard / 2000]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('모델 ${AdditionSeed.v3.version}. 공식 교육과정은 미등록입니다. 아래 규칙은 demo_only이며 성취기준이 아닙니다. 이 화면은 과제를 바꾸지 않습니다.', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        Text('1자리 혼합 경계 ${sample.edges.edgesMilli.join(' · ')}', key: const Key('addition-band-edges'), style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
        Text('구간별 후보 ${sample.edges.counts.join(' · ')}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        Text('이번 10문항 ${sample.actualCounts.join(' · ')}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < _quotaCases.length; i++)
              ThinkToggleChip(
                label: _quotaCases[i].$1,
                icon: Icons.circle_outlined,
                selected: _quotaCase == i,
                onChanged: (_) => setState(() => _quotaCase = i),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('30문항 배정 ${quotas.join(', ')}', key: const Key('addition-quota'), style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('378+245 표준 ${standard}ms, 실제 2000ms이면 효율 ${efficiency!.toStringAsFixed(1)}. 속도는 ${cappedSpeed(efficiency)!.toStringAsFixed(1)}에서 멈춥니다.', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 12),
        for (final rule in demoAdditionRules) ...[
          Text('${rule.label} · ${rule.sourceKind}', style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          for (final example in rule.examples)
            Builder(builder: (context) {
              final item = parseAdditionList(example.expr, seed: _draft);
              final decision = item == null ? null : explainAdditionRule(rule, item);
              final mark = decision != null && decision.allowed == example.allowed ? (decision.allowed ? '허용' : '제외') : '불일치';
              final why = decision == null || decision.reasons.isEmpty ? '' : ' · ${decision.reasons.first}';
              return Text('${example.expr} · $mark$why', style: const TextStyle(color: kThinkSub, fontSize: 12));
            }),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _bias() {
    final n = int.tryParse(_n.text.trim()) ?? 0;
    final residual = double.tryParse(_residual.text.trim());
    final k = int.tryParse(_k.text.trim()) ?? 20;
    AdditionBiasResult? result;
    if (residual != null && n >= 0 && k > 0) {
      result = additionBiasCandidate(
        studentResidualMs: List<double>.filled(n, residual),
        priorK: k,
        quantile: 0.30,
        seedBaseMs: _draft.coeff('base').timeMs,
      );
    }
    final seedTwo = analyzeAddition(BigInt.two, BigInt.from(3));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('가상 잔차입니다. 학생 기록에 저장하지 않고, 비용도 바꾸지 않습니다. 자동 반영은 꺼져 있습니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        TextField(controller: _n, onChanged: (_) => setState(() {}), style: const TextStyle(color: kThinkText), decoration: thinkInputDecoration(label: '적격 학생 수')),
        const SizedBox(height: 8),
        TextField(controller: _residual, onChanged: (_) => setState(() {}), style: const TextStyle(color: kThinkText), decoration: thinkInputDecoration(label: '학생 잔차 ms')),
        const SizedBox(height: 8),
        TextField(controller: _k, onChanged: (_) => setState(() {}), style: const TextStyle(color: kThinkText), decoration: thinkInputDecoration(label: '강도 k')),
        const SizedBox(height: 8),
        Text(result?.reason ?? '입력을 확인해 주세요.', key: const Key('bias-reason'), style: const TextStyle(color: kThinkText, fontSize: 13)),
        if (result?.candidateBaseMs != null)
          Text('2+3 시드 ${(seedTwo.timeMs / 1000).toStringAsFixed(3)}초 → 후보 ${(result!.candidateBaseMs! / 1000).toStringAsFixed(3)}초', style: const TextStyle(color: kThinkSub, fontSize: 12)),
      ],
    );
  }
}

class _QuizItem {
  _QuizItem(this.expr, this.sum, this.referenceMs);
  final String expr;
  final BigInt sum;
  final int referenceMs;
  int elapsedMs = 0;
  bool correct = false;
}

String _milli(int milli) => (milli / 1000).toStringAsFixed(3);

String _num(double? value) => value == null ? '측정 전' : value.toStringAsFixed(1);
