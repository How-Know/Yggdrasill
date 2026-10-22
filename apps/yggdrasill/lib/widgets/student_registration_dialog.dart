import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:mneme_flutter/models/student_payment_info.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'dialog_tokens.dart';

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

  static String titleFor(Student? student) {
    return student == null ? '학생 등록' : '학생 정보 수정';
  }

  static Future<void> show({
    required BuildContext context,
    Student? student,
    required Future<void> Function(Student, StudentBasicInfo) onSave,
    required List<GroupInfo> groups,
  }) {
    final title = titleFor(student);
    return PreviewAcademyDialogRoute.show<void>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return StudentRegistrationDialog(
          student: student,
          onSave: onSave,
          groups: groups,
        );
      },
    );
  }

  @override
  State<StudentRegistrationDialog> createState() =>
      _StudentRegistrationDialogState();
}

class _StudentRegistrationDialogState extends State<StudentRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _schoolController;
  late final TextEditingController _phoneController;
  late final TextEditingController _parentPhoneController;
  final TextEditingController _memoController = ImeAwareTextEditingController();

  late final FocusNode _nameFocusNode;
  late final FocusNode _schoolFocusNode;
  late final FocusNode _parentPhoneFocusNode;
  late final FocusNode _phoneFocusNode;
  late final FocusNode _memoFocusNode;
  final GlobalKey _gradeAnchorKey = GlobalKey();
  final GlobalKey _paymentAnchorKey = GlobalKey();

  late DateTime _registrationDate;
  late EducationLevel _educationLevel;
  late Grade? _grade;
  GroupInfo? _selectedGroup;
  String _paymentType = 'monthly'; // 'monthly' 또는 'session'

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
        orElse: () => StudentWithInfo(
            student: student,
            basicInfo: StudentBasicInfo(studentId: student.id)),
      );
      basicInfo = match.basicInfo;
    }
    _nameController = ImeAwareTextEditingController(text: student?.name);
    _schoolController = ImeAwareTextEditingController(text: student?.school);
    _phoneController = ImeAwareTextEditingController(
        text: basicInfo?.phoneNumber ?? student?.phoneNumber);
    _parentPhoneController = ImeAwareTextEditingController(
        text: basicInfo?.parentPhoneNumber ?? student?.parentPhoneNumber);
    _memoController.text = basicInfo?.memo ?? '';
    _nameFocusNode = FocusNode();
    _schoolFocusNode = FocusNode();
    _parentPhoneFocusNode = FocusNode();
    _phoneFocusNode = FocusNode();
    _memoFocusNode = FocusNode();
    _registrationDate = DateTime.now();
    _educationLevel = student?.educationLevel ?? EducationLevel.elementary;

    _paymentType = 'monthly';
    if (student != null) {
      final grades = gradesByLevel[student.educationLevel] ?? const <Grade>[];
      _grade = grades.firstWhere(
        (g) => g.value == student.grade,
        orElse: () => grades.isNotEmpty
            ? grades.first
            : const Grade(EducationLevel.elementary, '1학년', 1),
      );
    } else {
      // 기본값: 초등 1학년
      _grade = (gradesByLevel[EducationLevel.elementary] ?? const <Grade>[])
              .isNotEmpty
          ? (gradesByLevel[EducationLevel.elementary] ?? const <Grade>[]).first
          : null;
    }
    _selectedGroup = student?.groupInfo;

    // 기존 결제/주차 정보가 있으면 주간 수업횟수/등록일자 초기화
    if (student != null) {
      final paymentInfo =
          DataManager.instance.getStudentPaymentInfo(student.id);
      if (paymentInfo != null) {
        _registrationDate = paymentInfo.registrationDate;
        _paymentType = paymentInfo.paymentMethod;
      }
    }

    for (final c in [
      _nameController,
      _schoolController,
      _phoneController,
      _parentPhoneController,
      _memoController,
    ]) {
      c.addListener(_onFieldChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nameFocusNode.requestFocus();
    });
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
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
    for (final c in [
      _nameController,
      _schoolController,
      _phoneController,
      _parentPhoneController,
      _memoController,
    ]) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    _nameFocusNode.dispose();
    _schoolFocusNode.dispose();
    _parentPhoneFocusNode.dispose();
    _phoneFocusNode.dispose();
    _memoFocusNode.dispose();
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

  String _gradeId(Grade grade) => '${grade.level.name}:${grade.value}';

  String _paymentLabel(String type) => type == 'monthly' ? '월 결제' : '횟수제';

  PreviewAcademyPanelStyle _style(BuildContext context) {
    return FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
  }

  Widget _fieldDivider(PreviewAcademyPanelStyle style) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
      endIndent: FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
      color: style.divider,
    );
  }

  Future<void> _pickGrade(PreviewAcademyPanelStyle style) async {
    final anchor =
        _gradeAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchor == null) return;
    final grades = _flattenGrades();
    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: anchor,
      style: style,
      selectedId: _grade == null ? '' : _gradeId(_grade!),
      options: [
        for (final grade in grades)
          PreviewAcademyMenuOption(
              id: _gradeId(grade), label: _gradeLabel(grade)),
      ],
    );
    if (pickedId == null || !mounted) return;
    Grade? next;
    for (final grade in grades) {
      if (_gradeId(grade) == pickedId) {
        next = grade;
        break;
      }
    }
    if (next == null) return;
    final selected = next;
    final levelChanged = _grade != null && _grade!.level != selected.level;
    setState(() {
      _grade = selected;
      _educationLevel = selected.level;
    });
    if (levelChanged) _schoolController.clear();
  }

  Future<void> _pickPayment(PreviewAcademyPanelStyle style) async {
    final anchor =
        _paymentAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchor == null) return;
    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: anchor,
      style: style,
      selectedId: _paymentType,
      options: const [
        PreviewAcademyMenuOption(id: 'monthly', label: '월 결제'),
        PreviewAcademyMenuOption(id: 'session', label: '횟수제'),
      ],
    );
    if (pickedId == null || !mounted) return;
    setState(() => _paymentType = pickedId);
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
              surface: kDlgBg,
              onSurface: Color(0xFFEAF2F2),
            ),
            dialogBackgroundColor: kDlgBg,
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
    print(
        '[DEBUG][dialog] _phoneController.text: \'${_phoneController.text}\'');
    print(
        '[DEBUG][dialog] _parentPhoneController.text: \'${_parentPhoneController.text}\'');
    print('[DEBUG][dialog] _registrationDate: $_registrationDate');
    print('[DEBUG][dialog] _selectedGroup?.id: ${_selectedGroup?.id}');
    if (_nameController.text.isEmpty ||
        _schoolController.text.isEmpty ||
        _grade == null) {
      return;
    }

    if (schoolNameLikelyMiddleWhenHighLevel(
        _schoolController.text, _educationLevel)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '고등 과정인데 학교명이 중학교 형태로 보입니다. 진학한 고등학교명을 수정한 뒤 다시 저장해 주세요.',
            ),
          ),
        );
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
      parentPhoneNumber: _parentPhoneController.text.isEmpty
          ? null
          : _parentPhoneController.text,
      groupInfo: null,
      groupId: _selectedGroup?.id,
    );

    // BasicInfo에서는 등록일자와 지불방식을 제거 (student_payment_info로 이관)
    final basicInfo = StudentBasicInfo(
      studentId: student.id,
      phoneNumber: _phoneController.text.isEmpty ? null : _phoneController.text,
      parentPhoneNumber: _parentPhoneController.text.isEmpty
          ? null
          : _parentPhoneController.text,
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
    final style = _style(context);
    final title = StudentRegistrationDialog.titleFor(widget.student);
    // '보호자 연락처'가 한 줄에 들어가게 라벨 칸을 112로 둔다.
    const labelWidth = 112.0;

    return PreviewAcademyDialogSheet(
      style: style,
      title: title,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _handleSave,
      child: PreviewAcademyDialogGroupedFields(
        style: style,
        children: [
          PreviewAcademyDialogFieldRow(
            style: style,
            labelWidth: labelWidth,
            label: '이름',
            controller: _nameController,
            focusNode: _nameFocusNode,
            textInputAction: TextInputAction.next,
            onSubmitted: _schoolFocusNode.requestFocus,
            emptyHintText: '필수입력',
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            labelWidth: labelWidth,
            label: '학교',
            controller: _schoolController,
            focusNode: _schoolFocusNode,
            textInputAction: TextInputAction.next,
            onSubmitted: _parentPhoneFocusNode.requestFocus,
            emptyHintText: '필수입력',
          ),
          _fieldDivider(style),
          PreviewAcademyDialogPickerRow(
            style: style,
            labelWidth: labelWidth,
            anchorKey: _gradeAnchorKey,
            label: '학년',
            value: _grade == null ? '학년 선택' : _gradeLabel(_grade!),
            valueMuted: _grade == null,
            onTap: () => _pickGrade(style),
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            labelWidth: labelWidth,
            label: '보호자 연락처',
            controller: _parentPhoneController,
            focusNode: _parentPhoneFocusNode,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            onSubmitted: _phoneFocusNode.requestFocus,
            emptyHintText: '미입력',
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            labelWidth: labelWidth,
            label: '학생 연락처',
            controller: _phoneController,
            focusNode: _phoneFocusNode,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            onSubmitted: _memoFocusNode.requestFocus,
            emptyHintText: '미입력',
          ),
          _fieldDivider(style),
          PreviewAcademyDialogPickerRow(
            style: style,
            labelWidth: labelWidth,
            label: '등록일자',
            value: DateFormat('yyyy년 MM월 dd일').format(_registrationDate),
            onTap: () => _selectDate(context),
          ),
          _fieldDivider(style),
          PreviewAcademyDialogPickerRow(
            style: style,
            labelWidth: labelWidth,
            anchorKey: _paymentAnchorKey,
            label: '지불 방식',
            value: _paymentLabel(_paymentType),
            onTap: () => _pickPayment(style),
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            labelWidth: labelWidth,
            label: '메모',
            controller: _memoController,
            focusNode: _memoFocusNode,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            maxLines: 3,
            minLines: 1,
            emptyHintText: '미입력',
          ),
        ],
      ),
    );
  }
}
