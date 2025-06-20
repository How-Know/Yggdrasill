import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/class_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class StudentRegistrationDialog extends StatefulWidget {
  final Student? student;
  final Function(Student) onSave;
  final List<ClassInfo> classes;

  const StudentRegistrationDialog({
    Key? key,
    this.student,
    required this.onSave,
    required this.classes,
  }) : super(key: key);

  @override
  State<StudentRegistrationDialog> createState() => _StudentRegistrationDialogState();
}

class _StudentRegistrationDialogState extends State<StudentRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _schoolController;
  late final TextEditingController _phoneController;
  late final TextEditingController _parentPhoneController;
  late DateTime _registrationDate;
  late EducationLevel _educationLevel;
  late Grade? _grade;
  ClassInfo? _selectedClass;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.student?.name);
    _schoolController = TextEditingController(text: widget.student?.school);
    _phoneController = TextEditingController(text: widget.student?.phoneNumber);
    _parentPhoneController = TextEditingController(text: widget.student?.parentPhoneNumber);
    _registrationDate = widget.student?.registrationDate ?? DateTime.now();
    _educationLevel = widget.student?.educationLevel ?? EducationLevel.elementary;
    
    if (widget.student != null) {
      final grades = gradesByLevel[widget.student!.educationLevel] ?? [];
      _grade = grades.firstWhere(
        (g) => g.value == widget.student!.grade,
        orElse: () => grades.first,
      );
    } else {
      final grades = gradesByLevel[_educationLevel] ?? [];
      _grade = grades.isNotEmpty ? grades.first : null;
    }
    
    _selectedClass = widget.student?.classInfo;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _schoolController.dispose();
    _phoneController.dispose();
    _parentPhoneController.dispose();
    super.dispose();
  }

  String _getEducationLevelName(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초등';
      case EducationLevel.middle:
        return '중등';
      case EducationLevel.high:
        return '고등';
    }
  }

  List<int> _getGradeRange(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return List.generate(6, (i) => i + 1);
      case EducationLevel.middle:
      case EducationLevel.high:
        return List.generate(3, (i) => i + 1);
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _registrationDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF2A2A2A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF1F1F1F),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _registrationDate) {
      setState(() {
        _registrationDate = picked;
      });
    }
  }

  void _handleSave() {
    if (_nameController.text.isEmpty || _schoolController.text.isEmpty || _grade == null) {
      return;
    }

    final student = Student(
      id: widget.student?.id ?? const Uuid().v4(),
      name: _nameController.text,
      school: _schoolController.text,
      grade: _grade!.value,
      educationLevel: _educationLevel,
      phoneNumber: _phoneController.text.isEmpty ? null : _phoneController.text,
      parentPhoneNumber: _parentPhoneController.text.isEmpty ? null : _parentPhoneController.text,
      registrationDate: _registrationDate,
      classInfo: _selectedClass,
    );

    widget.onSave(student);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.student == null ? '학생 등록' : '학생 정보 수정',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _schoolController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '학교',
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
                  child: DropdownButtonFormField<ClassInfo?>(
                    value: _selectedClass,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF2A2A2A),
                    decoration: InputDecoration(
                      labelText: '클래스',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('없음', style: TextStyle(color: Colors.white)),
                      ),
                      ...widget.classes.map((classInfo) {
                        return DropdownMenuItem(
                          value: classInfo,
                          child: Text(classInfo.name, style: const TextStyle(color: Colors.white)),
                        );
                      }),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedClass = value;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<EducationLevel>(
                    value: _educationLevel,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF2A2A2A),
                    decoration: InputDecoration(
                      labelText: '과정',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    items: EducationLevel.values.map((level) {
                      return DropdownMenuItem(
                        value: level,
                        child: Text(
                          _getEducationLevelName(level),
                          style: const TextStyle(color: Colors.white),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _educationLevel = value;
                          final grades = gradesByLevel[value] ?? [];
                          _grade = grades.isNotEmpty ? grades.first : null;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<Grade>(
                    value: _grade,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF2A2A2A),
                    decoration: InputDecoration(
                      labelText: '학년',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    items: (gradesByLevel[_educationLevel] ?? []).map((grade) {
                      return DropdownMenuItem(
                        value: grade,
                        child: Text(grade.name, style: const TextStyle(color: Colors.white)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _grade = value;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneController,
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
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _parentPhoneController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '보호자 연락처',
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
            InkWell(
              onTap: () => _selectDate(context),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: '등록일자',
                  labelStyle: const TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      DateFormat('yyyy년 MM월 dd일').format(_registrationDate),
                      style: const TextStyle(color: Colors.white),
                    ),
                    const Icon(
                      Icons.calendar_today,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: const Text('등록', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
} 