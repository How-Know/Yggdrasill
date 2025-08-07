import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:mneme_flutter/models/student_payment_info.dart';

class StudentRegistrationDialog extends StatefulWidget {
  final Student? student;
  final Function(Student, StudentBasicInfo) onSave;
  final List<GroupInfo> groups;

  const StudentRegistrationDialog({
    Key? key,
    this.student,
    required this.onSave,
    required this.groups,
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
  GroupInfo? _selectedGroup;
  // [지불 방식 관련 상태 변수 및 컨트롤러 추가]
  String _paymentType = 'monthly'; // 'monthly' 또는 'session'
  final TextEditingController _paymentCycleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final student = widget.student;
    StudentBasicInfo? basicInfo;
    if (student != null) {
      // DataManager에서 StudentWithInfo로 들어온 경우라면, StudentBasicInfo를 찾아서 사용
      final studentsWithInfo = DataManager.instance.students;
      final match = studentsWithInfo.firstWhere(
        (s) => s.student.id == student.id,
        orElse: () => StudentWithInfo(student: student, basicInfo: StudentBasicInfo(studentId: student.id)),
      );
      basicInfo = match.basicInfo;
    }
    _nameController = TextEditingController(text: student?.name);
    _schoolController = TextEditingController(text: student?.school);
    _phoneController = TextEditingController(text: basicInfo?.phoneNumber ?? student?.phoneNumber);
    _parentPhoneController = TextEditingController(text: basicInfo?.parentPhoneNumber ?? student?.parentPhoneNumber);
    _registrationDate = DateTime.now();
    _educationLevel = student?.educationLevel ?? EducationLevel.elementary;

    // [지불 방식 데이터 초기화 추가]
    _paymentType = 'monthly';
    _paymentCycleController.text = '1';
    if (student != null) {
      final grades = gradesByLevel[student.educationLevel] ?? [];
      _grade = grades.firstWhere(
        (g) => g.value == student.grade,
        orElse: () => grades.first,
      );
    } else {
      final grades = gradesByLevel[_educationLevel] ?? [];
      _grade = grades.isNotEmpty ? grades.first : null;
    }
    _selectedGroup = student?.groupInfo;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _schoolController.dispose();
    _phoneController.dispose();
    _parentPhoneController.dispose();

    _paymentCycleController.dispose();
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

  void _handleSave() async {
    print('[DEBUG][dialog] _phoneController.text: \'${_phoneController.text}\'');
    print('[DEBUG][dialog] _parentPhoneController.text: \'${_parentPhoneController.text}\'');
    print('[DEBUG][dialog] _registrationDate: $_registrationDate');
    print('[DEBUG][dialog] _selectedGroup?.id: ${_selectedGroup?.id}');
    if (_nameController.text.isEmpty || _schoolController.text.isEmpty || _grade == null) {
      return;
    }
    
    final studentId = widget.student?.id ?? const Uuid().v4();
    final student = Student(
      id: studentId,
      name: _nameController.text,
      school: _schoolController.text,
      grade: _grade!.value,
      educationLevel: _educationLevel,
      phoneNumber: _phoneController.text.isEmpty ? null : _phoneController.text,
      parentPhoneNumber: _parentPhoneController.text.isEmpty ? null : _parentPhoneController.text,
      groupInfo: null,
      groupId: _selectedGroup?.id,
    );
    
    // BasicInfo에서는 등록일자와 지불방식을 제거 (student_payment_info로 이관)
    final basicInfo = StudentBasicInfo(
      studentId: student.id,
      phoneNumber: _phoneController.text.isEmpty ? null : _phoneController.text,
      parentPhoneNumber: _parentPhoneController.text.isEmpty ? null : _parentPhoneController.text,
      groupId: _selectedGroup?.id,
    );
    
    // StudentPaymentInfo 생성 (등록일자와 지불방식을 여기에 저장)
    final paymentInfo = StudentPaymentInfo(
      id: const Uuid().v4(),
      studentId: studentId,
      registrationDate: _registrationDate,
      paymentMethod: _paymentType,
      tuitionFee: 0, // 기본값
      latenessThreshold: 10, // 기본값
      scheduleNotification: false,
      attendanceNotification: false,
      departureNotification: false,
      latenessNotification: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    
    // 저장
    widget.onSave(student, basicInfo);
    
    // StudentPaymentInfo도 저장
    try {
      await DataManager.instance.addStudentPaymentInfo(paymentInfo);
      print('[INFO] StudentPaymentInfo 저장 완료');
    } catch (e) {
      print('[ERROR] StudentPaymentInfo 저장 실패: $e');
    }
    
    Navigator.of(context).pop(student);
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
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _paymentType,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF2A2A2A),
                    decoration: InputDecoration(
                      labelText: '지불 방식',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'monthly',
                        child: Text('월 결제', style: TextStyle(color: Colors.white)),
                      ),
                      DropdownMenuItem(
                        value: 'session',
                        child: Text('횟수제', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _paymentType = value;
                        });
                      }
                    },
                  ),
                ),
                if (_paymentType == 'session') ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _paymentCycleController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: '결제 주기',
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
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: Text(
            widget.student == null ? '등록' : '수정',
            style: const TextStyle(color: Colors.white)
          ),
        ),
      ],
    );
  }
} 