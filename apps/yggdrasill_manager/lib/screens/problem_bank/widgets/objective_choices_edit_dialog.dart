import 'package:flutter/material.dart';

import '../problem_bank_models.dart';

/// 매니저 UI 에서 문항 단위로 "객관식 5지선다 보기 + 정답 라벨" 을 직접 편집하는 다이얼로그.
///
/// 워크플로우:
///   1) 사용자가 "객관식 허용" 체크박스를 켜면 Gemini 로 5지선다가 자동 생성된다.
///   2) 생성된 보기가 마음에 들지 않으면 이 다이얼로그에서 문구/정답을 직접 다듬는다.
///   3) 저장 버튼을 누르면 결과가 [ObjectiveChoicesEditResult] 로 반환되고,
///      화면 상위 로직이 DB 에 반영한다. (취소 시 `null` 반환)
///
/// 선택적으로 "AI 로 재생성" 버튼을 제공한다. [onRegenerate] 가 null 이 아니면 다이얼로그에 노출되며,
/// 비동기 호출이 끝나면 [seedChoices], [seedAnswerKey] 를 덮어써 편집 영역을 갱신한다.
class ObjectiveChoicesEditDialog extends StatefulWidget {
  const ObjectiveChoicesEditDialog({
    super.key,
    required this.initialChoices,
    required this.initialAnswerKey,
    this.onRegenerate,
    this.title,
  });

  final List<ProblemBankChoice> initialChoices;
  final String initialAnswerKey;

  /// 눌렀을 때 AI 로 보기를 다시 생성한다. 새 결과를 돌려주면 편집 영역이 갱신된다.
  /// 반환이 null 이면 갱신하지 않고 사용자 편집 상태를 유지.
  final Future<ObjectiveChoicesRegenerateResult?> Function()? onRegenerate;
  final String? title;

  static Future<ObjectiveChoicesEditResult?> show(
    BuildContext context, {
    required List<ProblemBankChoice> initialChoices,
    required String initialAnswerKey,
    Future<ObjectiveChoicesRegenerateResult?> Function()? onRegenerate,
    String? title,
  }) {
    return showDialog<ObjectiveChoicesEditResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ObjectiveChoicesEditDialog(
        initialChoices: initialChoices,
        initialAnswerKey: initialAnswerKey,
        onRegenerate: onRegenerate,
        title: title,
      ),
    );
  }

  @override
  State<ObjectiveChoicesEditDialog> createState() =>
      _ObjectiveChoicesEditDialogState();
}

class _ObjectiveChoicesEditDialogState
    extends State<ObjectiveChoicesEditDialog> {
  static const List<String> _labels = <String>['①', '②', '③', '④', '⑤'];

  late List<TextEditingController> _controllers;
  late Set<String> _answerKeys;
  bool _regenerating = false;

  @override
  void initState() {
    super.initState();
    _controllers = List<TextEditingController>.generate(
      _labels.length,
      (_) => TextEditingController(),
      growable: false,
    );
    _seed(widget.initialChoices, widget.initialAnswerKey);
  }

  void _seed(List<ProblemBankChoice> choices, String answerKey) {
    for (var i = 0; i < _labels.length; i += 1) {
      final text = i < choices.length ? choices[i].text : '';
      _controllers[i].text = text;
    }
    final parsed = _parseAnswerKeys(answerKey);
    _answerKeys = parsed.isNotEmpty ? parsed : <String>{_labels.first};
  }

  Set<String> _parseAnswerKeys(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return <String>{};
    final circled = RegExp(r'[①②③④⑤]').allMatches(raw).map((m) => m.group(0)!);
    final out = <String>{...circled};
    if (out.isNotEmpty) return out;
    final normalized = raw
        .replaceAll(RegExp(r'[，、ㆍ·/]'), ',')
        .replaceAll(RegExp(r'\s*(와|과|및|그리고|또는)\s*'), ',');
    final parts = normalized.contains(',')
        ? normalized.split(',')
        : RegExp(r'^\d(?:\s+\d)+$').hasMatch(normalized)
            ? normalized.split(RegExp(r'\s+'))
            : <String>[normalized];
    for (final part in parts) {
      final n = int.tryParse(
        part.replaceAll(RegExp(r'[()（）.]'), '').replaceAll('번', '').trim(),
      );
      if (n != null && n >= 1 && n <= _labels.length) {
        out.add(_labels[n - 1]);
      }
    }
    return out;
  }

  String get _answerKey =>
      _labels.where((label) => _answerKeys.contains(label)).join(', ');

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _handleRegenerate() async {
    final cb = widget.onRegenerate;
    if (cb == null || _regenerating) return;
    setState(() {
      _regenerating = true;
    });
    try {
      final result = await cb();
      if (!mounted) return;
      if (result != null && result.choices.isNotEmpty) {
        setState(() {
          _seed(result.choices, result.answerKey);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _regenerating = false;
        });
      }
    }
  }

  void _submit() {
    final choices = <ProblemBankChoice>[];
    for (var i = 0; i < _labels.length; i += 1) {
      final text = _controllers[i].text.trim();
      choices.add(ProblemBankChoice(label: _labels[i], text: text));
    }
    final nonEmpty = choices.where((c) => c.text.isNotEmpty).length;
    if (nonEmpty < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('보기를 2개 이상 입력해 주세요.')),
      );
      return;
    }
    if (_answerKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('정답을 1개 이상 선택해 주세요.')),
      );
      return;
    }
    Navigator.of(context).pop(
      ObjectiveChoicesEditResult(
        choices: choices,
        answerKey: _answerKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title ?? '객관식 보기 수정'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '각 번호의 보기 문구를 다듬고, 정답을 하나 이상 체크한 뒤 저장하세요. '
              '수식은 \$...\$ 또는 \\(...\\) 형태를 그대로 사용할 수 있습니다.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _labels.length; i += 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _answerKeys.contains(_labels[i]),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _answerKeys.add(_labels[i]);
                          } else {
                            _answerKeys.remove(_labels[i]);
                          }
                        });
                      },
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        _labels[i],
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _controllers[i],
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          hintText: '${_labels[i]} 보기 내용',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.onRegenerate != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _regenerating ? null : _handleRegenerate,
                    icon: _regenerating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: Text(_regenerating ? '생성 중...' : 'AI 로 다시 생성'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '기존 보기를 덮어씁니다. Gemini 응답이 부족하면 기존 입력이 유지돼요.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class ObjectiveChoicesEditResult {
  const ObjectiveChoicesEditResult({
    required this.choices,
    required this.answerKey,
  });

  final List<ProblemBankChoice> choices;
  final String answerKey;
}

class ObjectiveChoicesRegenerateResult {
  const ObjectiveChoicesRegenerateResult({
    required this.choices,
    required this.answerKey,
  });

  final List<ProblemBankChoice> choices;
  final String answerKey;
}
