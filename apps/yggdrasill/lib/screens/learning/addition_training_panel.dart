import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

import '../../widgets/dialog_tokens.dart';
import '../../widgets/utility_glass_dialog_shell.dart';

const additionHomeworkKind = 'natural_addition_v3';

class AdditionApplyPayload {
  const AdditionApplyPayload({required this.title, required this.content, required this.count});

  final String title;
  final String content;
  final int count;
}

class AdditionTrainingPanel extends StatefulWidget {
  const AdditionTrainingPanel({super.key, required this.onClose, required this.onApply, this.embedded = false});

  final VoidCallback onClose;
  final void Function(String title, String content, int count) onApply;
  final bool embedded;

  @override
  State<AdditionTrainingPanel> createState() => AdditionTrainingPanelState();
}

class AdditionTrainingPanelState extends State<AdditionTrainingPanel> {
  int _arity = 2;
  final _digits = [2, 2, 2, 2, 2];
  CarryFilter _carry = CarryFilter.mixed;
  int _count = 30;
  final _bands = [true, true, true, true, true];
  final _weights = [1, 1, 1, 1, 1];
  bool _ratios = false;
  bool _sameDigits = true;
  bool _showAnswers = false;
  TrainingResult? _preview;
  int _seed = 1;
  String blockReason = '미리보기를 만든 뒤 과제 내기를 누르세요.';

  TrainingRequest get _request => TrainingRequest(
        digits: [for (var i = 0; i < _arity; i++) _digits[i]],
        carry: _carry,
        count: _count,
        bands: List<bool>.from(_bands),
        weights: List<int>.from(_weights),
        seed: _seed,
      );

  List<int> get _activeWeights => [for (var i = 0; i < 5; i++) _bands[i] ? _weights[i] : 0];

  bool get _weightsUsable => _activeWeights.any((weight) => weight > 0);

  void _clearPreview() => _preview = null;

  void _previewNow() {
    setState(() => _preview = generateAdditionSet(_request));
  }

  AdditionApplyPayload? takeApplyPayload() {
    final result = _preview;
    if (result == null) {
      blockReason = '미리보기를 만든 뒤 과제 내기를 누르세요.';
      return null;
    }
    if (result.items.isEmpty || result.short) {
      blockReason = result.note;
      return null;
    }
    return AdditionApplyPayload(
      title: '자연수 덧셈 ${result.items.length}문항',
      content: jsonEncode({
        'kind': additionHomeworkKind,
        'modelId': 'natural.addition',
        'procedureId': 'sequential_left_fold_v1',
        'seed': _seed,
        'edgesMilli': result.edges.edgesMilli,
        'items': [for (final item in result.items) item.toJson()],
      }),
      count: result.items.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final planned = hamiltonQuotas(_count, _activeWeights);
    final active = _activeWeights.fold<int>(0, (sum, weight) => sum + weight);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.embedded)
          Row(
            children: [
              IconButton(
                tooltip: '교재 선택으로',
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back, color: kDlgTextSub),
              ),
              const Expanded(
                child: Text('자연수 덧셈', style: TextStyle(color: UtilityGlassDialogTokens.iconColor, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        const Text('1구간이 연산량이 적고 5구간이 많습니다. 학교 등급이 아닙니다.', style: TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        _label('항 개수'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final n in [2, 3, 4, 5])
              _choice('$n', _arity == n, () => setState(() {
                    _arity = n;
                    _clearPreview();
                  })),
          ],
        ),
        const SizedBox(height: 14),
        _label('자릿수'),
        const SizedBox(height: 8),
        for (var i = 0; i < _arity; i++) ...[
          if (_arity > 2 && !_sameDigits)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${i + 1}번째', style: const TextStyle(color: kDlgTextSub, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final digit in [1, 2, 3])
                _choice('$digit자리', _digits[i] == digit, () => setState(() {
                      if (_sameDigits) {
                        for (var n = 0; n < _digits.length; n++) {
                          _digits[n] = digit;
                        }
                      } else {
                        _digits[i] = digit;
                      }
                      _clearPreview();
                    })),
            ],
          ),
          if (i < _arity - 1 && !_sameDigits) const SizedBox(height: 8),
        ],
        if (_arity > 2)
          TextButton(
            onPressed: () => setState(() => _sameDigits = !_sameDigits),
            style: TextButton.styleFrom(foregroundColor: kDlgAccent, padding: const EdgeInsets.symmetric(horizontal: 0)),
            child: Text(_sameDigits ? '항마다 자릿수 다르게' : '모든 항 같은 자릿수', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        const SizedBox(height: 8),
        _label('받아올림'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _choice('없음', _carry == CarryFilter.none, () => setState(() {
                  _carry = CarryFilter.none;
                  _clearPreview();
                })),
            _choice('있음', _carry == CarryFilter.some, () => setState(() {
                  _carry = CarryFilter.some;
                  _clearPreview();
                })),
            _choice('혼합', _carry == CarryFilter.mixed, () => setState(() {
                  _carry = CarryFilter.mixed;
                  _clearPreview();
                })),
          ],
        ),
        const SizedBox(height: 14),
        _label('문항 수'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final n in [10, 20, 30, 50])
              _choice('$n', _count == n, () => setState(() {
                    _count = n;
                    _clearPreview();
                  })),
          ],
        ),
        const SizedBox(height: 14),
        _label('출제 구간'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < 5; i++)
              _choice('${i + 1} · ${planned[i]}', _bands[i], () => setState(() {
                    _bands[i] = !_bands[i];
                    _clearPreview();
                  })),
          ],
        ),
        TextButton(
          onPressed: () => setState(() => _ratios = !_ratios),
          style: TextButton.styleFrom(foregroundColor: kDlgText, padding: const EdgeInsets.symmetric(horizontal: 0)),
          child: Text(_ratios ? '비율 조절 접기' : '비율 조절', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        if (_ratios) ...[
          TextButton(
            onPressed: () => setState(() {
              for (var i = 0; i < 5; i++) {
                if (_bands[i]) _weights[i] = 1;
              }
              _clearPreview();
            }),
            style: TextButton.styleFrom(foregroundColor: kDlgAccent, padding: const EdgeInsets.symmetric(horizontal: 0)),
            child: const Text('균등으로 되돌리기', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          for (var i = 0; i < 5; i++)
            Row(
              children: [
                SizedBox(width: 18, child: Text('${i + 1}', style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w700))),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: kDlgAccent,
                      inactiveTrackColor: kDlgBorder,
                      thumbColor: kDlgAccent,
                      overlayColor: kDlgAccent.withValues(alpha: 0.12),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _weights[i].toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      onChanged: _bands[i]
                          ? (value) => setState(() {
                                _weights[i] = value.round();
                                _clearPreview();
                              })
                          : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    _bands[i] ? '${active == 0 ? 0 : (100 * _weights[i] / active).round()}% · ${planned[i]}' : '0% · 0',
                    style: const TextStyle(color: kDlgTextSub, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Text('계획 배정 ${planned.join(' · ')}', key: const Key('addition-plan'), style: const TextStyle(color: kDlgText, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _bars(planned, null),
        ],
        if (!_weightsUsable)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('선택한 구간의 가중치가 모두 0입니다.', style: TextStyle(color: kDlgTextSub, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _pill(
              '미리보기 생성',
              filled: true,
              onTap: _bands.any((on) => on) && _weightsUsable ? _previewNow : null,
            ),
            _pill(
              '새로 생성',
              filled: false,
              onTap: () => setState(() {
                _seed += 1;
                _clearPreview();
              }),
            ),
          ],
        ),
        if (_preview != null) ...[
          const SizedBox(height: 12),
          Text(_preview!.note, style: const TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('만든 ${_preview!.items.length} / 요청 $_count', style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w800, fontSize: 14)),
          if (_preview!.items.isNotEmpty) ...[
            const SizedBox(height: 4),
            _summary(_preview!),
          ],
          const SizedBox(height: 8),
          _bars(_preview!.quotas, _preview!.actualCounts),
          TextButton(
            onPressed: () => setState(() => _showAnswers = !_showAnswers),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub, padding: const EdgeInsets.symmetric(horizontal: 0)),
            child: Text(_showAnswers ? '정답 숨기기' : '정답 보기', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          for (final item in _preview!.items.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _showAnswers ? '${item.expr} = ${item.answer}  ·  ${item.band}구간' : '${item.expr}  ·  ${item.band}구간',
                style: const TextStyle(color: kDlgText, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 8),
          _pill(
            '초안에 넣기',
            filled: true,
            key: const Key('addition-apply'),
            onTap: _preview!.items.isEmpty || _preview!.short
                ? null
                : () {
                    final payload = takeApplyPayload();
                    if (payload == null) return;
                    widget.onApply(payload.title, payload.content, payload.count);
                  },
          ),
        ],
      ],
    );
  }

  Widget _label(String text) {
    return Text(text, style: const TextStyle(color: kDlgTextSub, fontSize: 12.5, fontWeight: FontWeight.w700));
  }

  Widget _summary(TrainingResult result) {
    final costs = [for (final item in result.items) item.costMilli];
    final minCost = costs.reduce((a, b) => a < b ? a : b) / 1000;
    final maxCost = costs.reduce((a, b) => a > b ? a : b) / 1000;
    final avg = costs.fold<int>(0, (sum, cost) => sum + cost) / costs.length / 1000;
    return Text(
      '비용 ${minCost.toStringAsFixed(3)}–${maxCost.toStringAsFixed(3)}점, 평균 ${avg.toStringAsFixed(3)}점 · 받아올림 ${result.withCarry} · 없음 ${result.withoutCarry}',
      style: const TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600),
    );
  }

  Widget _bars(List<int> planned, List<int>? actual) {
    final values = actual ?? planned;
    final peak = values.fold<int>(1, (max, value) => value > max ? value : max);
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 5; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      actual == null ? '${planned[i]}' : '${actual[i]}/${planned[i]}',
                      style: const TextStyle(color: kDlgTextSub, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: mathMax(2, 36 * values[i] / peak),
                      decoration: BoxDecoration(
                        color: _bands[i] ? kDlgAccent : kDlgBorder,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) {
    final borderColor = selected ? kDlgAccent.withValues(alpha: 0.9) : kDlgBorder;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0x1A33A373) : kDlgFieldBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kDlgText : kDlgTextSub,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, {required bool filled, required VoidCallback? onTap, Key? key}) {
    final enabled = onTap != null;
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? (enabled ? kDlgAccent : kDlgFieldBg) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: filled ? null : Border.all(color: kDlgBorder),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: filled && enabled ? Colors.white : kDlgTextSub,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

double mathMax(num a, num b) => a > b ? a.toDouble() : b.toDouble();
