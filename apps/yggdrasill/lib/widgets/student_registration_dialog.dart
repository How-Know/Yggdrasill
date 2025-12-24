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
  final TextEditingController _weeklyClassCountController = ImeAwareTextEditingController(text: '1');

  // 필수 필드 포커스 및 시각적 피드백
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _schoolFocusNode = FocusNode();
  bool _blinkName = false;
  bool _blinkSchool = false;
  bool _forceErrorName = false;
  bool _forceErrorSchool = false;

  late DateTime _registrationDate;
  late EducationLevel _educationLevel;
  late Grade? _grade;
  GroupInfo? _selectedGroup;
  // [지불 방식 관련 상태 변수 및 컨트롤러 추가]
  String _paymentType = 'monthly'; // 'monthly' 또는 'session'
  final TextEditingController _paymentCycleController = ImeAwareTextEditingController();

  // 입력 완료 상태 확인용
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

    // 기존 결제/주차 정보가 있으면 주간 수업횟수/등록일자 초기화
    if (student != null) {
      final paymentInfo = DataManager.instance.getStudentPaymentInfo(student.id);
      if (paymentInfo != null) {
        _weeklyClassCountController.text = (paymentInfo.weeklyClassCount).toString();
        _registrationDate = paymentInfo.registrationDate;
        _paymentType = paymentInfo.paymentMethod;
      }
    }

    // 초기 유효성 검사 상태 설정
    _isNameValid = _nameController.text.isNotEmpty;
    _isSchoolValid = _schoolController.text.isNotEmpty;

    // 리스너 등록
    _nameController.addListener(() {
      setState(() {
        _isNameValid = _nameController.text.isNotEmpty;
        if (_isNameValid) _forceErrorName = false;
      });
    });
    _schoolController.addListener(() {
      setState(() {
        _isSchoolValid = _schoolController.text.isNotEmpty;
        if (_isSchoolValid) _forceErrorSchool = false;
      });
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _schoolController.dispose();
    _phoneController.dispose();
    _parentPhoneController.dispose();
    _nameFocusNode.dispose();
    _schoolFocusNode.dispose();

    _paymentCycleController.dispose();
    _weeklyClassCountController.dispose();
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

  String _courseGradeLabel(Grade g) {
    final levelName = _getEducationLevelName(g.level);
    final gradeName = g.isRepeater ? 'N수생' : g.name;
    return '$levelName $gradeName';
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
              primary: Color(0xFF33A373), // Accent color
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

  Future<void> _triggerBlink({
    required bool forName,
  }) async {
    // 에러 강조: 한 번 깜빡이고 빨간색 유지
    setState(() {
      if (forName) {
        _blinkName = true;
        _forceErrorName = true;
      } else {
        _blinkSchool = true;
        _forceErrorSchool = true;
      }
    });
    final focusNode = forName ? _nameFocusNode : _schoolFocusNode;
    focusNode.requestFocus();
    await Future.delayed(const Duration(milliseconds: 160));
    setState(() {
      if (forName) {
        _blinkName = false;
      } else {
        _blinkSchool = false;
      }
    });
  }

  void _handleSave() async {
    final missingName = _nameController.text.isEmpty;
    final missingSchool = _schoolController.text.isEmpty;
    if (missingName || missingSchool || _grade == null) {
      // 가장 먼저 빈 필드로 포커스 및 깜빡임
      if (missingName) {
        _triggerBlink(forName: true);
      } else if (missingSchool) {
        _triggerBlink(forName: false);
      }
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
    
    // 증가 방어: 보강(예정) 존재 시 주간 수업횟수 증가 불가
    final newWeeklyCount = int.tryParse(_weeklyClassCountController.text.trim()) ?? 1;
    if (widget.student != null) {
      final existingInfo = DataManager.instance.getStudentPaymentInfo(studentId);
      final oldWeeklyCount = existingInfo?.weeklyClassCount ?? 1;
      if (newWeeklyCount > oldWeeklyCount) {
        final hasPlannedMakeup = DataManager.instance.sessionOverrides.any((ov) =>
            ov.studentId == studentId &&
            ov.status == OverrideStatus.planned &&
            (ov.overrideType == OverrideType.replace || ov.overrideType == OverrideType.add));
        if (hasPlannedMakeup) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              title: const Text('증가 불가', style: TextStyle(color: Colors.white)),
              content: const Text('보강을 취소한 뒤에 주간수업횟수를 늘려주세요.', style: TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          return;
        }
      }
    }

    // StudentPaymentInfo 생성 (등록일자와 지불방식을 여기에 저장)
    final paymentInfo = StudentPaymentInfo(
      id: const Uuid().v4(),
      studentId: studentId,
      registrationDate: _registrationDate,
      paymentMethod: _paymentType,
      weeklyClassCount: newWeeklyCount,
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

  InputDecoration _buildInputDecoration(
    String label, {
    bool required = false,
    bool isValid = false,
    bool blink = false,
    bool forceError = false,
  }) {
    final baseColor = const Color(0xFF3A3F44).withOpacity(0.6);
    final errorColor = const Color(0xFFF04747);
    final isError = blink || forceError;
    final borderColor = isError ? errorColor : baseColor;
    return InputDecoration(
      labelText: required ? '$label *' : label,
      labelStyle: TextStyle(
        color: isError ? errorColor : const Color(0xFF9FB3B3),
        fontSize: 14,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: isError ? errorColor : const Color(0xFF33A373)),
      ),
      filled: true,
      fillColor: const Color(0xFF15171C),
      suffixIcon: (required && isValid) 
          ? const Icon(Icons.check_circle, color: Color(0xFF33A373), size: 18) 
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0B1112), // Dark background matching student tab
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF223131)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: Text(
        widget.student == null ? '학생 등록' : '학생 정보 수정',
        style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 20, fontWeight: FontWeight.bold),
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

              // 1. 필수 정보 섹션
              _buildSectionHeader('필수 정보'),
              Row(
                children: [
                  Expanded(
                    child: CustomFormDropdown<Grade>(
                      label: '과정/학년',
                      value: _grade,
                      items: gradesByLevel.values.expand((e) => e).toList(),
                      itemLabelBuilder: (g) => _courseGradeLabel(g),
                      onChanged: (value) {
                        setState(() {
                          _grade = value;
                          _educationLevel = value.level;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _nameController,
                      focusNode: _nameFocusNode,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration(
                        '이름',
                        required: true,
                        isValid: _isNameValid,
                        blink: _blinkName,
                        forceError: _forceErrorName,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _schoolController,
                      focusNode: _schoolFocusNode,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration(
                        '학교',
                        required: true,
                        isValid: _isSchoolValid,
                        blink: _blinkSchool,
                        forceError: _forceErrorSchool,
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 2. 기본 정보 섹션
              _buildSectionHeader('기본 정보'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _weeklyClassCountController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('주간 수업 횟수'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _phoneController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('학생 연락처'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _parentPhoneController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('보호자 연락처'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 3. 추가 정보 섹션
              _buildSectionHeader('추가 정보'),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectDate(context),
                      child: InputDecorator(
                        decoration: _buildInputDecoration('등록일자'),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              DateFormat('yyyy년 MM월 dd일').format(_registrationDate),
                              style: const TextStyle(color: Color(0xFFEAF2F2)),
                            ),
                            const Icon(Icons.calendar_today, color: Color(0xFF9FB3B3), size: 18),
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
            backgroundColor: const Color(0xFF33A373), // Accent color
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
