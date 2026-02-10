import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../../widgets/dialog_tokens.dart';

class HomeworkEditDialog extends StatefulWidget {
  final String initialTitle;
  final String initialBody;
  final Color initialColor;
  final String? initialType;
  final String? initialPage;
  final int? initialCount;
  final String? initialContent;
  const HomeworkEditDialog({
    super.key,
    required this.initialTitle,
    required this.initialBody,
    required this.initialColor,
    this.initialType,
    this.initialPage,
    this.initialCount,
    this.initialContent,
  });

  @override
  State<HomeworkEditDialog> createState() => _HomeworkEditDialogState();
}

class _HomeworkEditDialogState extends State<HomeworkEditDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _page;
  late final TextEditingController _count;
  late String _type;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle);
    _content = ImeAwareTextEditingController(text: _seedContent());
    _page = ImeAwareTextEditingController(text: widget.initialPage ?? '');
    _count = ImeAwareTextEditingController(
        text: widget.initialCount != null ? widget.initialCount.toString() : '');
    final initialType = (widget.initialType ?? '').trim();
    _type = initialType.isNotEmpty
        ? initialType
        : (_inferTypeFromColor(widget.initialColor) ?? '프린트');
    _color = _colorForType(_type);
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _page.dispose();
    _count.dispose();
    super.dispose();
  }

  String _seedContent() {
    final initial = (widget.initialContent ?? '').trim();
    if (initial.isNotEmpty) return initial;
    return widget.initialBody.trim();
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

  String? _inferTypeFromColor(Color color) {
    if (color.value == Colors.blue.value) return '프린트';
    if (color.value == Colors.green.value) return '교재';
    if (color.value == Colors.amber.value) return '문제집';
    if (color.value == Colors.purple.value) return '학습';
    if (color.value == Colors.red.value) return '테스트';
    return null;
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
      title:
          const Text('과제 편집', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(icon: Icons.task_alt, title: '과제 정보'),
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
                    style:
                        const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
                    decoration: _inputDecoration('페이지', hint: '예: 10-12'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _count,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style:
                        const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
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
          onPressed: () => Navigator.of(context).pop(null),
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
            Navigator.of(context).pop({
              'title': title,
              'body': _composeBody(),
              'color': _color,
              'type': _type,
              'page': _page.text.trim(),
              'count': _count.text.trim(),
              'content': _content.text.trim(),
            });
          },
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('저장'),
        ),
      ],
    );
  }
}





