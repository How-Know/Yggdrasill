import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class HomeworkQuickAddProxyDialog extends StatefulWidget {
  final String studentId;
  final String? initialTitle;
  final Color? initialColor;
  const HomeworkQuickAddProxyDialog({required this.studentId, this.initialTitle, this.initialColor});
  @override
  State<HomeworkQuickAddProxyDialog> createState() => HomeworkQuickAddProxyDialogState();
}

class HomeworkQuickAddProxyDialogState extends State<HomeworkQuickAddProxyDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late Color _color;
  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle ?? '');
    _body = ImeAwareTextEditingController(text: '');
    _color = widget.initialColor ?? const Color(0xFF1976D2);
  }
  @override
  void dispose() { _title.dispose(); _body.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과제 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '과제 이름', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '내용', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
            const SizedBox(height: 12),
            const Text('색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in [Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.pink, Colors.cyan, Colors.teal, Colors.red, const Color(0xFF90A4AE)])
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: c == _color ? Colors.white : Colors.white24, width: c == _color ? 2 : 1),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            final body = _body.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, {
              'studentId': widget.studentId,
              'title': title,
              'body': body,
              'color': _color,
            });
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
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


