import 'package:flutter/material.dart';

import '../../../services/concept_service.dart';

Future<ConceptFormResult?> showConceptInputDialog(
  BuildContext context, {
  ConceptItem? initial,
}) {
  return showDialog<ConceptFormResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConceptInputDialog(initial: initial),
  );
}

class _ConceptInputDialog extends StatefulWidget {
  const _ConceptInputDialog({required this.initial});

  final ConceptItem? initial;

  @override
  State<_ConceptInputDialog> createState() => _ConceptInputDialogState();
}

class _ConceptInputDialogState extends State<_ConceptInputDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _symbolCtrl;
  late final TextEditingController _contentCtrl;
  ConceptKind _kind = ConceptKind.definition;
  String _subType = '정의';
  int _level = 1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _kind = initial?.kind ?? ConceptKind.definition;
    _subType = initial?.subType ?? '정의';
    _level = initial?.level ?? 1;
    _nameCtrl = TextEditingController(text: initial?.name ?? '');
    _symbolCtrl = TextEditingController(text: initial?.symbol ?? '');
    _contentCtrl = TextEditingController(text: initial?.content ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _symbolCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _nameCtrl.text.trim().isNotEmpty &&
      _contentCtrl.text.trim().isNotEmpty &&
      !_saving;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2B2B),
      title: Text(
        widget.initial == null ? '개념 추가' : '개념 수정',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildKindSelector(),
              const SizedBox(height: 12),
              _buildSubtypeSelector(),
              const SizedBox(height: 12),
              _buildTextField(
                label: '이름',
                controller: _nameCtrl,
                hint: '개념명을 입력하세요',
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: '기호 (선택)',
                controller: _symbolCtrl,
                hint: '예) α, A, f(x)',
              ),
              const SizedBox(height: 12),
              _buildLevelSelector(),
              const SizedBox(height: 12),
              _buildContentField(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('저장'),
        ),
      ],
    );
  }

  Widget _buildKindSelector() {
    return Row(
      children: [
        const Text('구분', style: TextStyle(color: Colors.white70)),
        const Spacer(),
        SegmentedButton<ConceptKind>(
          segments: const [
            ButtonSegment(
              value: ConceptKind.definition,
              label: Text('정의'),
            ),
            ButtonSegment(
              value: ConceptKind.theorem,
              label: Text('정리'),
            ),
          ],
          selected: <ConceptKind>{_kind},
          onSelectionChanged: (value) {
            setState(() => _kind = value.first);
          },
        ),
      ],
    );
  }

  Widget _buildSubtypeSelector() {
    const options = ['정의', '연산', '정리'];
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '세부 유형',
        labelStyle: TextStyle(color: Colors.white70),
        enabledBorder:
            OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF3A3A3A))),
        focusedBorder:
            OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF4A9EFF))),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _subType,
          dropdownColor: const Color(0xFF2B2B2B),
          items: options
              .map(
                (e) => DropdownMenuItem(
                  value: e,
                  child: Text(e, style: const TextStyle(color: Colors.white)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => _subType = value);
            }
          },
        ),
      ),
    );
  }

  Widget _buildLevelSelector() {
    return Row(
      children: [
        const Text('레벨', style: TextStyle(color: Colors.white70)),
        const SizedBox(width: 12),
        DropdownButton<int>(
          value: _level,
          dropdownColor: const Color(0xFF2B2B2B),
          items: const [
            DropdownMenuItem(value: 1, child: Text('1')),
            DropdownMenuItem(value: 2, child: Text('2')),
            DropdownMenuItem(value: 3, child: Text('3')),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _level = value);
            }
          },
        ),
      ],
    );
  }

  Widget _buildContentField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '내용',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3A3A3A)),
          ),
          child: TextField(
            controller: _contentCtrl,
            maxLines: 8,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '개념 내용을 입력하세요. 수식은 LaTeX 형식으로 작성할 수 있습니다.',
              hintStyle: TextStyle(color: Colors.white38),
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF3A3A3A)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF4A9EFF)),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _saving = true);
    final result = ConceptFormResult(
      kind: _kind,
      subType: _subType,
      name: _nameCtrl.text.trim(),
      content: _contentCtrl.text.trim(),
      level: _level,
      symbol: _symbolCtrl.text.trim().isEmpty
          ? null
          : _symbolCtrl.text.trim(),
    );
    Navigator.pop(context, result);
  }
}

class ConceptFormResult {
  ConceptFormResult({
    required this.kind,
    required this.subType,
    required this.name,
    required this.content,
    required this.level,
    this.symbol,
  });

  final ConceptKind kind;
  final String subType;
  final String name;
  final String content;
  final int level;
  final String? symbol;
}














































