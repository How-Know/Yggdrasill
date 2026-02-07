import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../../widgets/dialog_tokens.dart';
import '../../models/student_flow.dart';

class HomeworkQuickAddProxyDialog extends StatefulWidget {
  final String studentId;
  final String? initialTitle;
  final Color? initialColor;
  final List<StudentFlow> flows;
  final String? initialFlowId;
  const HomeworkQuickAddProxyDialog({
    required this.studentId,
    required this.flows,
    this.initialTitle,
    this.initialColor,
    this.initialFlowId,
  });
  @override
  State<HomeworkQuickAddProxyDialog> createState() => HomeworkQuickAddProxyDialogState();
}

class HomeworkQuickAddProxyDialogState extends State<HomeworkQuickAddProxyDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _page;
  late final TextEditingController _count;
  late Color _color;
  String _type = '프린트';
  late String _flowId;
  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle ?? '');
    _content = ImeAwareTextEditingController(text: '');
    _page = ImeAwareTextEditingController(text: '');
    _count = ImeAwareTextEditingController(text: '');
    _color = _colorForType(_type);
    final initial = widget.initialFlowId;
    if (initial != null && widget.flows.any((f) => f.id == initial)) {
      _flowId = initial;
    } else {
      _flowId = widget.flows.isNotEmpty ? widget.flows.first.id : '';
    }
  }
  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _page.dispose();
    _count.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: kDlgTextSub),
      hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Color _colorForType(String type) {
    switch (type) {
      case '프린트':
        return Colors.blue;
      case '교재':
        return Colors.green;
      case '문제집':
        return Colors.amber;
      case '학습':
        return Colors.purple;
      case '테스트':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  String _composeBody() {
    final content = _content.text.trim();
    final page = _page.text.trim();
    final count = _count.text.trim();
    final parts = <String>[];
    if (page.isNotEmpty) parts.add('p.$page');
    if (count.isNotEmpty) parts.add('${count}문항');
    if (parts.isEmpty) return content;
    if (content.isEmpty) return parts.join(' / ');
    return '${parts.join(' / ')}\n$content';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('과제 추가', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(icon: Icons.task_alt, title: '과제 정보'),
            DropdownButtonFormField<String>(
              value: _flowId.isEmpty ? null : _flowId,
              items: widget.flows
                  .map((f) => DropdownMenuItem(value: f.id, child: Text(f.name)))
                  .toList(),
              onChanged: (v) => setState(() {
                _flowId = v ?? _flowId;
              }),
              decoration: _inputDecoration('플로우'),
              dropdownColor: kDlgPanelBg,
              style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
              iconEnabledColor: kDlgTextSub,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _type,
              items: const [
                DropdownMenuItem(value: '프린트', child: Text('프린트')),
                DropdownMenuItem(value: '교재', child: Text('교재')),
                DropdownMenuItem(value: '문제집', child: Text('문제집')),
                DropdownMenuItem(value: '학습', child: Text('학습')),
                DropdownMenuItem(value: '테스트', child: Text('테스트')),
              ],
              onChanged: (v) => setState(() {
                _type = v ?? '프린트';
                _color = _colorForType(_type);
              }),
              decoration: _inputDecoration('과제 유형'),
              dropdownColor: kDlgPanelBg,
              style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
              iconEnabledColor: kDlgTextSub,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
              decoration: _inputDecoration('과제명', hint: '예: 프린트 1장'),
            ),
            const SizedBox(height: 6),
            const Text(
              '과제명만 입력해도 저장됩니다.',
              style: TextStyle(color: kDlgTextSub, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _page,
                    keyboardType: TextInputType.text,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9\-~,/ ]')),
                    ],
                    style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                    decoration: _inputDecoration('페이지', hint: '예: 10-12'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _count,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                    decoration: _inputDecoration('문항수', hint: '예: 12'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _content,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: kDlgText),
              decoration: _inputDecoration('내용', hint: '필요한 추가 내용을 적어주세요'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('과제명을 입력하세요.')),
              );
              return;
            }
            if (_flowId.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('플로우를 선택하세요.')),
              );
              return;
            }
            Navigator.pop(context, {
              'studentId': widget.studentId,
              'flowId': _flowId,
              'type': _type,
              'title': title,
              'page': _page.text.trim(),
              'count': _count.text.trim(),
              'content': _content.text.trim(),
              'body': _composeBody(),
              'color': _color,
            });
          },
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('추가'),
        ),
      ],
    );
  }
}

// 이어가기: 제목/색상은 고정 표기, 내용만 입력
class HomeworkContinueDialog extends StatefulWidget {
  final String studentId;
  final String title;
  final Color color;
  const HomeworkContinueDialog({required this.studentId, required this.title, required this.color});
  @override
  State<HomeworkContinueDialog> createState() => _HomeworkContinueDialogState();
}

class _HomeworkContinueDialogState extends State<HomeworkContinueDialog> {
  late final TextEditingController _body;
  @override
  void initState() {
    super.initState();
    _body = ImeAwareTextEditingController(text: '');
  }
  @override
  void dispose() { _body.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과제 이어가기', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.title, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)))
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '내용', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {'studentId': widget.studentId, 'body': _body.text.trim()});
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
        ),
      ],
    );
  }
}


