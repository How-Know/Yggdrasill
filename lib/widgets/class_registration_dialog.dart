import 'package:flutter/material.dart';
import '../models/class_info.dart';
import 'package:uuid/uuid.dart';

class ClassRegistrationDialog extends StatefulWidget {
  final bool editMode;
  final ClassInfo? classInfo;
  final int? index;
  final Function(ClassInfo) onSave;

  const ClassRegistrationDialog({
    super.key,
    this.editMode = false,
    this.classInfo,
    this.index,
    required this.onSave,
  });

  @override
  State<ClassRegistrationDialog> createState() => _ClassRegistrationDialogState();
}

class _ClassRegistrationDialogState extends State<ClassRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _capacityController;
  late int _duration;
  Color _selectedColor = Colors.blue;

  final List<Color> _colors = [
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    const Color(0xFF2196F3),
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.classInfo?.name ?? '');
    _descriptionController = TextEditingController(text: widget.classInfo?.description ?? '');
    _capacityController = TextEditingController(text: widget.classInfo?.capacity.toString() ?? '');
    _duration = widget.classInfo?.duration ?? 60;
    if (widget.classInfo != null) {
      _selectedColor = widget.classInfo!.color;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final capacity = int.tryParse(_capacityController.text.trim()) ?? 30;
    final duration = _duration;
    final color = _selectedColor;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('클래스명을 입력해주세요')),
      );
      return;
    }

    if (widget.editMode) {
      final updatedClass = widget.classInfo!.copyWith(
        name: name,
        description: description,
        capacity: capacity,
        duration: duration,
        color: color,
      );
      widget.onSave(updatedClass);
    } else {
      final newClass = ClassInfo(
        id: const Uuid().v4(),
        name: name,
        description: description,
        capacity: capacity,
        duration: duration,
        color: color,
      );
      widget.onSave(newClass);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.editMode ? '클래스 수정' : '클래스 등록',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '클래스명',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _capacityController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '정원',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '설명',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '색상',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
                return Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedColor = color;
                      });
                    },
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _selectedColor == color ? Colors.white : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            '취소',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: Text(widget.editMode ? '수정' : '등록'),
        ),
      ],
    );
  }
} 