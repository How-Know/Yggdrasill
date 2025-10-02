import 'package:flutter/material.dart';
import '../models/teacher.dart';

class TeacherRegistrationDialog extends StatefulWidget {
  final Teacher? teacher;
  final Function(Teacher) onSave;

  const TeacherRegistrationDialog({
    Key? key,
    this.teacher,
    required this.onSave,
  }) : super(key: key);

  @override
  State<TeacherRegistrationDialog> createState() => _TeacherRegistrationDialogState();
}

class _TeacherRegistrationDialogState extends State<TeacherRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _contactController;
  late final TextEditingController _emailController;
  late final TextEditingController _descriptionController;
  TeacherRole _role = TeacherRole.all;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.teacher?.name ?? '');
    _contactController = TextEditingController(text: widget.teacher?.contact ?? '');
    _emailController = TextEditingController(text: widget.teacher?.email ?? '');
    _descriptionController = TextEditingController(text: widget.teacher?.description ?? '');
    _role = widget.teacher?.role ?? TeacherRole.all;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    _emailController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _handleSave() {
    if (_nameController.text.trim().isEmpty) return;
    final teacher = Teacher(
      name: _nameController.text.trim(),
      role: _role,
      contact: _contactController.text.trim(),
      email: _emailController.text.trim(),
      description: _descriptionController.text.trim(),
      displayOrder: null,
    );
    widget.onSave(teacher);
    Navigator.of(context).pop(teacher);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.teacher == null ? '선생님 등록' : '선생님 정보 수정',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 400,
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
                      labelText: '이름',
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
                  child: DropdownButtonFormField<TeacherRole>(
                    value: _role,
                    decoration: InputDecoration(
                      labelText: '역할',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    dropdownColor: const Color(0xFF23232A),
                    style: const TextStyle(color: Colors.white),
                    items: TeacherRole.values.map((r) => DropdownMenuItem(
                      value: r,
                      child: Text(getTeacherRoleLabel(r)),
                    )).toList(),
                    onChanged: (v) { if (v != null) setState(() { _role = v; }); },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _contactController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: '연락처',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: '이메일',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: '설명',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0xFF23232A),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
          ),
          onPressed: _handleSave,
          child: const Text('저장'),
        ),
      ],
    );
  }
} 