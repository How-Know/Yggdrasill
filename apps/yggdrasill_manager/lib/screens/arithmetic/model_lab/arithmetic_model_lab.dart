import 'package:flutter/material.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

import '../../../services/arithmetic_model_repository.dart';
import '../../think/think_style.dart';
import 'arithmetic_model_simulators.dart';

/// 개념 탭 연산 시트의 '모델' 칸. 운영 비용과 문항 점수는 바꾸지 않는다.
class ArithmeticModelLab extends StatefulWidget {
  const ArithmeticModelLab({super.key, this.repository});

  /// null이면 네트워크 없이 로컬 계산만 한다.
  final ArithmeticModelRepository? repository;

  @override
  State<ArithmeticModelLab> createState() => _ArithmeticModelLabState();
}

class _ArithmeticModelLabState extends State<ArithmeticModelLab> {
  static const _sections = ['개요', '시뮬레이터', '설정', '설명', '이력'];

  ModelPolicy _live = ModelPolicy.initial;
  int _expectedVersion = 0;
  List<ModelEventRow> _events = const [];
  int _seedCount = 0;
  String? _status;
  int _section = 0;
  int _simulator = 0;
  final _expr = TextEditingController(text: '13-8');
  final _reason = TextEditingController();
  final _accuracy = TextEditingController(text: '98');
  final _speed = TextEditingController(text: '90');
  final _k = TextEditingController(text: '20');
  final _anchor = TextEditingController(text: '50');
  String _analyzed = '13-8';
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    if (widget.repository != null) {
      _load();
    } else {
      _status = '이 화면의 계산은 기기 안에서 돌아갑니다. 운영 발행은 로그인한 관리자 세션에서 합니다.';
    }
  }

  @override
  void dispose() {
    _expr.dispose();
    _reason.dispose();
    _accuracy.dispose();
    _speed.dispose();
    _k.dispose();
    _anchor.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap = await widget.repository!.load();
      if (!mounted) return;
      setState(() {
        _live = snap.policy ?? ModelPolicy.initial;
        _expectedVersion = snap.policy?.version ?? 0;
        _events = snap.events;
        _seedCount = snap.seedCount;
        _fillDraftFields(_live);
        _status = snap.policy == null
            ? '운영 정책 행이 아직 없습니다. 아래는 코드의 초기 정책입니다.'
            : '운영 정책 ${_live.version}을 읽고 있습니다. 측정 기록 쓰기는 아직 연결하지 않았습니다.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '운영 정책을 읽지 못했습니다. 계산은 초기 정책으로 계속합니다. $e');
    }
  }

  void _fillDraftFields(ModelPolicy policy) {
    _accuracy.text = policy.masteryAccuracyPct.toString();
    _speed.text = policy.masterySpeed.toString();
    _k.text = policy.priorStrengthK.toString();
    _anchor.text = policy.anchorScore.toString();
  }

  ModelPolicy? _draftFromFields() {
    final accuracy = double.tryParse(_accuracy.text.trim());
    final speed = double.tryParse(_speed.text.trim());
    final k = double.tryParse(_k.text.trim());
    final anchor = double.tryParse(_anchor.text.trim());
    if (accuracy == null || speed == null || k == null || anchor == null) return null;
    return _live.copyWith(
      masteryAccuracyPct: accuracy,
      masterySpeed: speed,
      priorStrengthK: k,
      anchorScore: anchor,
    );
  }

  Future<void> _publish() async {
    final repo = widget.repository;
    if (repo == null || _publishing) return;
    final draft = _draftFromFields();
    if (draft == null) {
      setState(() => _status = '숙련 정확도, 숙련 속도, k, 앵커는 숫자여야 합니다.');
      return;
    }
    final error = draft.validate();
    if (error != null) {
      setState(() => _status = error);
      return;
    }
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      setState(() => _status = '변경 사유를 적어 주세요. 발행 전에는 운영 값이 바뀌지 않습니다.');
      return;
    }
    setState(() => _publishing = true);
    try {
      await repo.publish(policy: draft, expectedVersion: _expectedVersion, reason: reason);
      _reason.clear();
      await _load();
      if (!mounted) return;
      setState(() => _status = '새 정책 버전을 발행했습니다. 과거 문항 점수는 그대로입니다.');
    } catch (e) {
      if (!mounted) return;
      final text = '$e';
      setState(() {
        _status = text.contains('arithmetic_model_conflict')
            ? '다른 저장이 먼저 되어 발행하지 않았습니다. 다시 읽어 주세요.'
            : '발행하지 못했습니다. $text';
      });
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kThinkBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('연산 모델', style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(_status ?? '초기 정책을 보여주는 중입니다.', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.35)),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < _sections.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        ThinkToggleChip(
                          label: _sections[i],
                          icon: Icons.circle_outlined,
                          selected: _section == i,
                          onChanged: (_) => setState(() => _section = i),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: kThinkBorder, height: 16),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                if (_section == 0) _overview(),
                if (_section == 1) _simulators(),
                if (_section == 2) _settings(),
                if (_section == 3) _guide(),
                if (_section == 4) _history(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview() {
    final parsed = parseNaturalExpression(_analyzed);
    final features = parsed.ok ? featuresOf(parsed.left!, parsed.right!, parsed.op!, parsed.display) : null;
    final found = features == null ? null : classifyFeatures(features);
    final empty = calibrate(CalibrationRequest(
      students: const [],
      cutoffUtc: DateTime.utc(2026, 6, 1),
      initialMs: 1000,
      activeMs: 1000,
      policy: _live,
    ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('자연수 유형 ${naturalSeeds.length}개 · 초안 ${draftSeeds.length}개 · 기준 시드 $_seedCount개', style: const TextStyle(color: kThinkText, fontSize: 13)),
        const SizedBox(height: 4),
        Text('정책 v${_live.version} · 숙련 정확도 ${_live.masteryAccuracyPct}% · 숙련 속도 ${_live.masterySpeed}점 · 앵커 ${_live.anchorScore}점(상한 아님)', style: const TextStyle(color: kThinkSub, fontSize: 12)),
        const SizedBox(height: 4),
        Text(empty.reasons.last, style: const TextStyle(color: kThinkSub, fontSize: 12)),
        const SizedBox(height: 12),
        const Text('식 분석', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          key: const Key('arithmetic-expression'),
          controller: _expr,
          style: const TextStyle(color: kThinkText, fontSize: 13),
          decoration: thinkInputDecoration(label: '자연수 식'),
          onSubmitted: (value) => setState(() => _analyzed = value),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: () => setState(() => _analyzed = _expr.text), child: const Text('분류 보기')),
        if (!parsed.ok) Text(parsed.message, style: const TextStyle(color: kThinkError, fontSize: 12)),
        if (found != null) ...[
          Text('결과 ${found.status} · 코드 ${found.code ?? '없음'}', key: const Key('expr-class'), style: const TextStyle(color: kThinkText, fontSize: 13)),
          if (features!.carryCount != null) Text('받아올림 ${features.carryCount}회 · 연속 ${features.carryChainLength}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          if (features.borrowCount != null) Text('받아내림 ${features.borrowCount}회 · 0 경유 ${features.zeroCrossingCount}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          Text('초안 후보 ${found.candidates.isEmpty ? '없음' : found.candidates.join(', ')}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          const Text('초안을 켜도 이미 저장된 문항 분류는 바꾸지 않습니다.', style: TextStyle(color: kThinkSub, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _simulators() {
    const names = ['학생 점수', '기준 시간', '문항 비용', '속성 시간', '학습 곡선', '비용과 시간'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < names.length; i++)
              ThinkToggleChip(
                label: names[i],
                icon: Icons.circle_outlined,
                selected: _simulator == i,
                onChanged: (_) => setState(() => _simulator = i),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_simulator == 0) StudentScoreSimulator(policy: _live),
        if (_simulator == 1) const CalibrationSimulator(),
        if (_simulator == 2) ProblemCostSimulator(policy: _live),
        if (_simulator == 3) const FeatureTimeSimulator(),
        if (_simulator == 4) const PersonalCurveSimulator(),
        if (_simulator == 5) const CostRelationSimulator(),
      ],
    );
  }

  Widget _settings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('아래 네 값만 초안으로 고칠 수 있습니다. 발행 전에는 운영 값이 아니고, 시뮬레이터 예시는 따라가지 않습니다.', style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        TextField(controller: _accuracy, style: const TextStyle(color: kThinkText, fontSize: 13), decoration: thinkInputDecoration(label: '숙련 정확도 %')),
        const SizedBox(height: 8),
        TextField(controller: _speed, style: const TextStyle(color: kThinkText, fontSize: 13), decoration: thinkInputDecoration(label: '숙련 속도 점')),
        const SizedBox(height: 8),
        TextField(controller: _k, style: const TextStyle(color: kThinkText, fontSize: 13), decoration: thinkInputDecoration(label: '초기값 강도 k')),
        const SizedBox(height: 8),
        TextField(controller: _anchor, style: const TextStyle(color: kThinkText, fontSize: 13), decoration: thinkInputDecoration(label: '최고난도 앵커')),
        const SizedBox(height: 12),
        for (final param in policyParameters()) ...[
          Text('${param.label} · ${param.unit}', style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          Text('${param.meaning} 근거: ${param.basis}. 영향: ${param.affects}', style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
          Text('지금 운영: ${_current(param.key)}', style: const TextStyle(color: kThinkHint, fontSize: 12)),
          const SizedBox(height: 10),
        ],
        TextField(
          controller: _reason,
          style: const TextStyle(color: kThinkText, fontSize: 13),
          decoration: thinkInputDecoration(label: '변경 사유'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => _fillDraftFields(ModelPolicy.initial)),
          child: const Text('초안만 초기값으로'),
        ),
        const SizedBox(height: 4),
        ElevatedButton(
          onPressed: widget.repository == null || _publishing ? null : _publish,
          style: thinkPrimaryButton(),
          child: Text(_publishing ? '발행 중' : '새 버전으로 발행'),
        ),
        const SizedBox(height: 8),
        const Text('발행은 정책 버전만 추가합니다. 연산 비용, 문항 점수, 학생 기록은 건드리지 않습니다.', style: TextStyle(color: kThinkSub, fontSize: 12)),
      ],
    );
  }

  String _current(String key) {
    final json = _live.toJson();
    final value = json[key];
    return value == null ? '비움' : '$value';
  }

  Widget _guide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in modelGuide) ...[
          Text(section.question, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(section.answer, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.45)),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _history() {
    if (_events.isEmpty) {
      return const Text('아직 이 화면에서 읽은 발행 이력이 없습니다. 마이그레이션 뒤 초기 정책 한 줄이 쌓입니다.', style: TextStyle(color: kThinkSub, fontSize: 13));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in _events)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${event.createdAt.toString().substring(0, 16)}  ${event.summary}', style: const TextStyle(color: kThinkText, fontSize: 12)),
          ),
      ],
    );
  }
}
