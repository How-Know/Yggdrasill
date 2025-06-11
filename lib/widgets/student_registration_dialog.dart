import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/class_info.dart';

class StudentRegistrationDialog extends StatefulWidget {
  final bool editMode;
  final Student? editingStudent;
  final List<ClassInfo> classes;

  const StudentRegistrationDialog({
    super.key,
    this.editMode = false,
    this.editingStudent,
    required this.classes,
  });

  @override
  State<StudentRegistrationDialog> createState() => _StudentRegistrationDialogState();
}

class _StudentRegistrationDialogState extends State<StudentRegistrationDialog> {
  late final TextEditingController nameController;
  late final TextEditingController schoolController;
  late final TextEditingController phoneController;
  late final TextEditingController parentPhoneController;
  
  EducationLevel? selectedEducationLevel;
  Grade? selectedGrade;
  ClassInfo? selectedClass;
  late DateTime selectedDate;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(
      text: widget.editMode ? widget.editingStudent!.name : '',
    );
    schoolController = TextEditingController(
      text: widget.editMode ? widget.editingStudent!.school : '',
    );
    phoneController = TextEditingController(
      text: widget.editMode ? widget.editingStudent!.phoneNumber : '',
    );
    parentPhoneController = TextEditingController(
      text: widget.editMode ? widget.editingStudent!.parentPhoneNumber : '',
    );
    
    selectedEducationLevel = widget.editMode ? widget.editingStudent!.educationLevel : null;
    selectedGrade = widget.editMode ? widget.editingStudent!.grade : null;
    selectedClass = widget.editMode ? widget.editingStudent!.classInfo : null;
    selectedDate = widget.editMode ? widget.editingStudent!.registrationDate : DateTime.now();
  }

  @override
  void dispose() {
    nameController.dispose();
    schoolController.dispose();
    phoneController.dispose();
    parentPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.editMode ? '학생 정보 수정' : '새 학생 등록',
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '기본 정보',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            // 이름
            SizedBox(
              width: 300,
              child: TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '이름',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText: '학생 이름을 입력하세요',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 클래스
            SizedBox(
              width: 300,
              child: DropdownButtonFormField<ClassInfo?>(
                value: selectedClass,
                style: const TextStyle(color: Colors.white),
                dropdownColor: const Color(0xFF1F1F1F),
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
                    child: Text(
                      '미소속',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  ...widget.classes.map((classInfo) {
                    return DropdownMenuItem(
                      value: classInfo,
                      child: Text(
                        classInfo.name,
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }).toList(),
                ],
                onChanged: (value) {
                  setState(() {
                    selectedClass = value;
                  });
                },
              ),
            ),
            const SizedBox(height: 16),
            // 과정과 학년을 나란히 배치
            Row(
              children: [
                // 과정
                SizedBox(
                  width: 140,
                  child: DropdownButtonFormField<EducationLevel>(
                    value: selectedEducationLevel,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF1F1F1F),
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
                          getEducationLevelName(level),
                          style: const TextStyle(color: Colors.white),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedEducationLevel = value;
                        selectedGrade = value != null ? gradesByLevel[value]!.first : null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 20),
                // 학년
                SizedBox(
                  width: 140,
                  child: DropdownButtonFormField<Grade>(
                    value: selectedGrade,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF1F1F1F),
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
                    items: selectedEducationLevel != null
                        ? gradesByLevel[selectedEducationLevel]!.map((grade) {
                            return DropdownMenuItem(
                              value: grade,
                              child: Text(
                                grade.name,
                                style: const TextStyle(color: Colors.white),
                              ),
                            );
                          }).toList()
                        : null,
                    onChanged: selectedEducationLevel != null
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                selectedGrade = value;
                              });
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 학교
            SizedBox(
              width: 300,
              child: TextField(
                controller: schoolController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '학교',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText: '학교 이름을 입력하세요',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 연락처
            SizedBox(
              width: 300,
              child: TextField(
                controller: phoneController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '연락처',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText: '선택 사항',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
                keyboardType: TextInputType.phone,
              ),
            ),
            const SizedBox(height: 16),
            // 부모님 연락처
            SizedBox(
              width: 300,
              child: TextField(
                controller: parentPhoneController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '부모님 연락처',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText: '선택 사항',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
                keyboardType: TextInputType.phone,
              ),
            ),
            const SizedBox(height: 16),
            // 등록일자
            SizedBox(
              width: 300,
              child: InkWell(
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    builder: (context, child) {
                      return Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: const ColorScheme.dark(
                            primary: Color(0xFF1976D2),
                            onPrimary: Colors.white,
                            surface: Color(0xFF1F1F1F),
                            onSurface: Colors.white,
                          ),
                          dialogBackgroundColor: const Color(0xFF1F1F1F),
                        ),
                        child: child!,
                      );
                    },
                  );
                  if (picked != null) {
                    setState(() {
                      selectedDate = picked;
                    });
                  }
                },
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
                  child: Text(
                    '${selectedDate.year}년 ${selectedDate.month}월 ${selectedDate.day}일',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
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
          onPressed: () {
            final name = nameController.text.trim();
            final school = schoolController.text.trim();
            final phone = phoneController.text.trim();
            final parentPhone = parentPhoneController.text.trim();

            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('학생 이름을 입력해주세요')),
              );
              return;
            }

            if (selectedEducationLevel == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('과정을 선택해주세요')),
              );
              return;
            }

            if (selectedGrade == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('학년을 선택해주세요')),
              );
              return;
            }

            // 새로운 학생 객체 생성
            final Student student = Student(
              name: name,
              educationLevel: selectedEducationLevel!,
              grade: selectedGrade!,
              school: school,
              classInfo: selectedClass,
              phoneNumber: phone,
              parentPhoneNumber: parentPhone,
              registrationDate: selectedDate,
            );

            // 다이얼로그를 닫고 결과 반환
            Navigator.pop(context, student);
          },
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: Text(widget.editMode ? '수정' : '등록'),
        ),
      ],
    );
  }
} 