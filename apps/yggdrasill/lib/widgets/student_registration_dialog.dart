import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:mneme_flutter/models/student_payment_info.dart';
import 'package:mneme_flutter/models/session_override.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:mneme_flutter/widgets/custom_form_dropdown.dart';

class StudentRegistrationDialog extends StatefulWidget {
  final Student? student;
  final Future<void> Function(Student, StudentBasicInfo) onSave;
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
  final TextEditingController _memoController = ImeAwareTextEditingController();

  late DateTime _registrationDate;
  late EducationLevel _educationLevel;
  late Grade? _grade;
  GroupInfo? _selectedGroup;
  // [지불 방식 관련 상태 변수 및 컨트롤러 추가]
  String _paymentType = 'monthly'; // 'monthly' 또는 'session'
  final TextEditingController _paymentCycleController = ImeAwareTextEditingController();

  // ✅ UI(신형 다이얼로그)에서 필수 입력 상태 표시용
  bool _isNameValid = false;
  bool _isSchoolValid = false;

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
    _nameController = ImeAwareTextEditingController(text: student?.name);
    _schoolController = ImeAwareTextEditingController(text: student?.school);
    _phoneController = ImeAwareTextEditingController(text: basicInfo?.phoneNumber ?? student?.phoneNumber);
    _parentPhoneController = ImeAwareTextEditingController(text: basicInfo?.parentPhoneNumber ?? student?.parentPhoneNumber);
    _memoController.text = basicInfo?.memo ?? '';
    _registrationDate = DateTime.now();
    _educationLevel = student?.educationLevel ?? EducationLevel.elementary;

    // [지불 방식 데이터 초기화 추가]
    _paymentType = 'monthly';
    _paymentCycleController.text = '1';
    if (student != null) {
      final grades = gradesByLevel[student.educationLevel] ?? const <Grade>[];
      _grade = grades.firstWhere(
        (g) => g.value == student.grade,
        orElse: () => grades.isNotEmpty ? grades.first : const Grade(EducationLevel.elementary, '1학년', 1),
      );
    } else {
      // 기본값: 초등 1학년
      _grade = (gradesByLevel[EducationLevel.elementary] ?? const <Grade>[]).isNotEmpty
          ? (gradesByLevel[EducationLevel.elementary] ?? const <Grade>[]).first
          : null;
    }
    _selectedGroup = student?.groupInfo;

    // 기존 결제/주차 정보가 있으면 주간 수업횟수/등록일자 초기화
    if (student != null) {
      final paymentInfo = DataManager.instance.getStudentPaymentInfo(student.id);
      if (paymentInfo != null) {
        _registrationDate = paymentInfo.registrationDate;
        _paymentType = paymentInfo.paymentMethod;
      }
    }

    // ✅ 초기 유효성 상태 + 리스너(구버전 UI로 돌아간 느낌 방지)
    _isNameValid = _nameController.text.trim().isNotEmpty;
    _isSchoolValid = _schoolController.text.trim().isNotEmpty;
    _nameController.addListener(() {
      final next = _nameController.text.trim().isNotEmpty;
      if (next == _isNameValid) return;
      setState(() => _isNameValid = next);
    });
    _schoolController.addListener(() {
      final next = _schoolController.text.trim().isNotEmpty;
      if (next == _isSchoolValid) return;
      setState(() => _isSchoolValid = next);
    });
  }

  List<Grade> _flattenGrades() {
    // ✅ 단일 드롭다운: "초등 1학년, ... 중등 1학년, ... 고등 N수" 순으로 고정
    return <Grade>[
      ...(gradesByLevel[EducationLevel.elementary] ?? const <Grade>[]),
      ...(gradesByLevel[EducationLevel.middle] ?? const <Grade>[]),
      ...(gradesByLevel[EducationLevel.high] ?? const <Grade>[]),
    ];
  }

  String _gradeLabel(Grade g) => '${_getEducationLevelName(g.level)} ${g.name}';

  @override
  void dispose() {
    _nameController.dispose();
    _schoolController.dispose();
    _phoneController.dispose();
    _parentPhoneController.dispose();

    _paymentCycleController.dispose();
    _memoController.dispose();
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
              primary: Color(0xFF33A373), // ✅ 시간표/수업블록 다이얼로그와 통일
              onPrimary: Colors.white,
              surface: Color(0xFF0B1112),
              onSurface: Color(0xFFEAF2F2),
            ),
            dialogBackgroundColor: const Color(0xFF0B1112),
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

  InputDecoration _buildInputDecoration(String label,
      {bool required = false, bool isValid = false}) {
    return InputDecoration(
      labelText: required ? '$label *' : label,
      labelStyle: const TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: const Color(0xFF3A3F44).withOpacity(0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF33A373)),
      ),
      filled: true,
      fillColor: const Color(0xFF15171C),
      suffixIcon: (required && isValid)
          ? const Icon(Icons.check_circle,
              color: Color(0xFF33A373), size: 18)
          : null,
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: const Color(0xFF33A373),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
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
      memo: _memoController.text.isEmpty ? null : _memoController.text,
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
    
    // 저장(학생/기본정보를 먼저 확실하게 저장한 뒤, 결제정보 저장)
    await widget.onSave(student, basicInfo);
    
    // StudentPaymentInfo도 저장
    try {
      await DataManager.instance.addStudentPaymentInfo(paymentInfo);
      print('[INFO] StudentPaymentInfo 저장 완료');
    } catch (e) {
      print('[ERROR] StudentPaymentInfo 저장 실패: $e');
    }
    
    // 다이얼로그 종료 전에 약간의 대기 후 닫기(목록 반영 타이밍 안정화)
    await Future.delayed(const Duration(milliseconds: 50));
    if (mounted) {
      Navigator.of(context).pop(student);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0B1112),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF223131)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: Text(
        widget.student == null ? '학생 등록' : '학생 정보 수정',
        style: const TextStyle(
          color: Color(0xFFEAF2F2),
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              _buildSectionHeader('필수 정보'),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _nameController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration(
                        '이름',
                        required: true,
                        isValid: _isNameValid,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _schoolController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration(
                        '학교',
                        required: true,
                        isValid: _isSchoolValid,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: CustomFormDropdown<Grade>(
                      label: '학년',
                      placeholder: '학년 선택',
                      value: _grade,
                      items: _flattenGrades(),
                      itemLabelBuilder: _gradeLabel,
                      onChanged: (value) {
                        setState(() {
                          _grade = value;
                          _educationLevel = value.level;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ✅ 위의 "이름/학교" 2열 레이아웃과 동일하게, 오른쪽 절반은 비워 폭을 1/2로 맞춘다.
                  const Expanded(flex: 3, child: SizedBox.shrink()),
                ],
              ),

              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              _buildSectionHeader('기본 정보'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _parentPhoneController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('보호자 연락처'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _phoneController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('학생 연락처'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              _buildSectionHeader('추가 정보'),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectDate(context),
                      borderRadius: BorderRadius.circular(8),
                      child: InputDecorator(
                        decoration: _buildInputDecoration('등록일자'),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              DateFormat('yyyy년 MM월 dd일').format(_registrationDate),
                              style: const TextStyle(color: Color(0xFFEAF2F2)),
                            ),
                            const Icon(
                              Icons.calendar_today,
                              color: Color(0xFF9FB3B3),
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CustomFormDropdown<String>(
                      label: '지불 방식',
                      value: _paymentType,
                      items: const ['monthly', 'session'],
                      itemLabelBuilder: (val) => val == 'monthly' ? '월 결제' : '횟수제',
                      onChanged: (value) {
                        setState(() => _paymentType = value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memoController,
                maxLines: 3,
                style: const TextStyle(color: Color(0xFFEAF2F2)),
                decoration: _buildInputDecoration('메모'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF9FB3B3),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(
            widget.student == null ? '등록' : '수정',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
} 

