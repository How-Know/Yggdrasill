import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class HomeworkEditDialog extends StatefulWidget {
  final String initialTitle;
  final String initialBody;
  final Color initialColor;
  const HomeworkEditDialog({super.key, required this.initialTitle, required this.initialBody, required this.initialColor});

  @override
  State<HomeworkEditDialog> createState() => _HomeworkEditDialogState();
}

class _HomeworkEditDialogState extends State<HomeworkEditDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _title = ImeAwareTextEditingController(text: widget.initialTitle);
    _body = ImeAwareTextEditingController(text: widget.initialBody);
    _color = widget.initialColor;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과제 편집', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '과제 이름',
                labelStyle: TextStyle(color: Colors.white60),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '내용',
                labelStyle: TextStyle(color: Colors.white60),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 12),
            const Text('색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in [
                  Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.pink,
                  Colors.cyan, Colors.teal, Colors.red, const Color(0xFF90A4AE)
                ])
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            final body = _body.text.trim();
            if (title.isEmpty) return;
            Navigator.of(context).pop({
              'title': title,
              'body': body,
              'color': _color,
            });
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}





