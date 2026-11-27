import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ygg_arithmetic/ygg_arithmetic.dart';

import '../../services/homework_store.dart';
import '../../widgets/dialog_tokens.dart';
import 'addition_training_panel.dart';

class AdditionSolvePage extends StatefulWidget {
  const AdditionSolvePage({
    super.key,
    required this.studentId,
    required this.item,
    this.onSaved,
    this.measureTime = true,
  });

  final String studentId;
  final HomeworkItem item;
  final void Function(String studentId, HomeworkItem item)? onSaved;

  /// 인쇄로 낸 과제는 시간을 재지 않고 정답만 확인한다.
  final bool measureTime;

  static bool matches(String? content) {
    final raw = (content ?? '').trim();
    return raw.startsWith('{"kind":"$additionHomeworkKind"');
  }

  @override
  State<AdditionSolvePage> createState() => _AdditionSolvePageState();
}

class _AdditionSolvePageState extends State<AdditionSolvePage> {
  late final List<Map<String, dynamic>> _items = _readItems();
  final _answer = TextEditingController();
  final _clock = Stopwatch();
  late int _index;
  final _elapsed = <int>[];
  final _correct = <bool>[];

  List<Map<String, dynamic>> _readItems() {
    final decoded = jsonDecode(widget.item.content ?? '{}');
    final list = decoded is Map ? decoded['items'] : null;
    if (list is! List) return const [];
    return [for (final row in list) if (row is Map) Map<String, dynamic>.from(row)];
  }

  @override
  void initState() {
    super.initState();
    if (_storedResult() != null) {
      _index = _items.length;
    } else {
      _index = 0;
      if (widget.measureTime) _clock.start();
    }
  }

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const Scaffold(body: Center(child: Text('문항이 없습니다.')));
    }
    if (_index >= _items.length) return _result();
    final item = _items[_index];
    return Scaffold(
      backgroundColor: kDlgBg,
      appBar: AppBar(
        backgroundColor: kDlgBg,
        foregroundColor: kDlgText,
        title: Text('${_index + 1}/${_items.length}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.measureTime)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('인쇄로 낸 과제입니다. 정답만 확인합니다.', style: TextStyle(color: kDlgTextSub, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            Text('${item['expr']}', style: const TextStyle(color: kDlgText, fontSize: 36, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(
              controller: _answer,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: kDlgText, fontSize: 22, fontWeight: FontWeight.w700),
              cursorColor: kDlgAccent,
              decoration: InputDecoration(
                labelText: '답',
                labelStyle: const TextStyle(color: kDlgTextSub),
                filled: true,
                fillColor: kDlgFieldBg,
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kDlgBorder)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kDlgAccent, width: 1.4)),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _submit,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: kDlgAccent, borderRadius: BorderRadius.circular(20)),
                  child: const Text('제출', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final item = _items[_index];
    final elapsed = widget.measureTime ? _clock.elapsedMilliseconds : 0;
    final given = _answer.text.trim();
    _elapsed.add(elapsed);
    _correct.add(given == '${item['answer']}');
    _answer.clear();
    if (widget.measureTime) {
      _clock
        ..reset()
        ..start();
    }
    final next = _index + 1;
    if (next >= _items.length) _save();
    setState(() => _index = next);
  }

  Map<String, dynamic>? _contentMap() {
    final decoded = jsonDecode(widget.item.content ?? '{}');
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic>? _storedResult() {
    final result = _contentMap()?['result'];
    if (result is! Map) return null;
    return Map<String, dynamic>.from(result);
  }

  void _save() {
    final ratios = <double>[];
    for (var i = 0; i < _items.length; i++) {
      if (!_correct[i]) continue;
      final standard = (_items[i]['timeMs'] as num?)?.toDouble() ?? 0;
      final actual = _elapsed[i];
      if (standard > 0 && actual > 0) ratios.add(standard / actual);
    }
    final efficiency = efficiencyIndex(ratios);
    final speed = cappedSpeed(efficiency);
    final accuracy = 100 * _correct.where((ok) => ok).length / _items.length;
    final fluency = fluencyScore(
      speed: speed,
      accuracy: accuracy,
      accuracyEligibleCount: _items.length,
      wSpeed: 1,
      wAccuracy: 1,
    );
    final saved = _contentMap();
    if (saved == null) return;
    saved['result'] = {
      'elapsedMs': _elapsed,
      'correct': _correct,
      'efficiency': efficiency,
      'speed': speed,
      'fluency': fluency,
      'accuracy': accuracy,
      'protocol': widget.measureTime ? '표준 절차 추정 대비' : '인쇄 과제, 시간 제외',
      'eligibleCount': ratios.length,
    };
    widget.item.content = jsonEncode(saved);
    widget.item.accumulatedMs = _elapsed.fold<int>(0, (sum, ms) => sum + ms);
    _persist();
  }

  void _persist() {
    final save = widget.onSaved;
    if (save != null) {
      save(widget.studentId, widget.item);
      return;
    }
    HomeworkStore.instance.edit(widget.studentId, widget.item);
  }

  void _retry() {
    final saved = _contentMap();
    if (saved != null) {
      saved.remove('result');
      widget.item.content = jsonEncode(saved);
      _persist();
    }
    _elapsed.clear();
    _correct.clear();
    _answer.clear();
    _clock
      ..reset()
      ..start();
    setState(() => _index = 0);
  }

  Widget _result() {
    final result = _storedResult();
    final accuracy = result?['accuracy'];
    final efficiency = result?['efficiency'];
    final speed = result?['speed'];
    final fluency = result?['fluency'];
    return Scaffold(
      backgroundColor: kDlgBg,
      appBar: AppBar(backgroundColor: kDlgBg, foregroundColor: kDlgText, title: const Text('결과')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.measureTime
                  ? '정확도 ${_text(accuracy)}\n효율 ${_text(efficiency)}\n속도 ${_text(speed)}\n숙련도 ${_text(fluency)}\n\n효율은 표준 절차 추정 시간 대비입니다. 기준보다 빠르면 100을 넘습니다. 속도는 100에서 멈춥니다.'
                  : '정확도 ${_text(accuracy)}\n\n인쇄로 낸 과제는 시간을 재지 않습니다.',
              style: const TextStyle(color: kDlgText, fontSize: 18, height: 1.5),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _retry, child: const Text('다시 풀기')),
          ],
        ),
      ),
    );
  }

  String _text(Object? value) {
    if (value is num) return value.toStringAsFixed(1);
    return '측정 전';
  }
}
