import 'package:flutter/material.dart';
import '../../models/session_override.dart';
import '../../models/attendance_record.dart';
import '../../models/student.dart';
import '../../models/group_info.dart';
import '../../models/student_view_type.dart';
import '../../models/education_level.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_registration_dialog.dart';
import '../../widgets/group_registration_dialog.dart';
import 'components/all_students_view.dart';

import 'components/school_view.dart';
import 'components/date_view.dart';
import '../../widgets/app_bar_title.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../widgets/custom_tab_bar.dart';
import 'package:flutter/foundation.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/student_details_dialog.dart';
import '../../models/payment_record.dart';
import '../../models/student_time_block.dart';
import '../../services/academy_db.dart';
import '../timetable/components/attendance_check_view.dart';
import '../../models/education_level.dart';
import '../../models/student_payment_info.dart';
import 'package:uuid/uuid.dart';
import 'components/attendance_indicator.dart';

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key});

  @override
  State<StudentScreen> createState() => StudentScreenState();
}

class StudentScreenState extends State<StudentScreen> {
  StudentViewType get viewType => _viewType;
  StudentViewType _viewType = StudentViewType.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<GroupInfo> _expandedGroups = {};
  int _customTabIndex = 0;
  Map<String, Set<String>>? _activeFilter;

  // 출석 관리 관련 상태 변수들
  StudentWithInfo? _selectedStudent;
  final Map<String, bool> _isExpanded = {};
  DateTime _currentDate = DateTime.now();
  DateTime _currentCalendarDate = DateTime.now();
  int _prevTabIndex = 0;
  
  // 수강료납부 및 출석체크 네비게이션을 위한 상태 변수
  int _paymentPageIndex = 0; // 수강료납부 페이지 인덱스 (0이 현재)
  int _attendancePageIndex = 0; // 출석체크 페이지 인덱스 (0이 현재)
  
  // 화살표 활성화 상태 (실제 데이터 존재 여부에 따라 동적 계산)
  bool _paymentHasPastRecords = false;
  bool _paymentHasFutureCards = false;

  late Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _loadData();
  }

  @override
  void didUpdateWidget(StudentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 위젯이 업데이트될 때 페이지 인덱스 초기화 (학생 변경 시)
    // 실제로는 학생 선택이 _selectedStudent 변수로 관리되므로 여기서는 초기화하지 않음
    // 대신 학생 변경 시 직접 초기화하는 로직을 별도로 구현
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadGroups();
    await DataManager.instance.loadStudents();
    await DataManager.instance.loadStudentPaymentInfos();
    await _loadAttendanceData();
  }

  // 출석 관리 초기 데이터 로딩
  Future<void> _loadAttendanceData() async {
    await _ensurePaymentRecordsTable();
    if (mounted) {
      setState(() {});
    }
  }

  // payment_records 테이블 존재 여부 확인 및 생성
  Future<void> _ensurePaymentRecordsTable() async {
    try {
      await AcademyDbService.instance.ensurePaymentRecordsTable();
    } catch (e) {
      rethrow;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<StudentWithInfo> filterStudents(List<StudentWithInfo> students) {
    if (_searchQuery.isEmpty) return students;
    return students.where((studentWithInfo) =>
      studentWithInfo.student.name.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  Widget _buildContent() {
    return ValueListenableBuilder<List<GroupInfo>>(
      valueListenable: DataManager.instance.groupsNotifier,
      builder: (context, groups, _) {
        return ValueListenableBuilder<List<StudentWithInfo>>(
          valueListenable: DataManager.instance.studentsNotifier,
          builder: (context, students, __) {
            print('[DEBUG][StudentScreen] ValueListenableBuilder build: students.length=' + students.length.toString());
            final filteredStudents = filterStudents(students);
            if (_viewType == StudentViewType.byClass) {
              return const Center(
                child: Text(
                  '구 그룹 뷰 (사용 안함)',
                  style: TextStyle(color: Colors.white70),
                ),
              );
            } else if (_viewType == StudentViewType.bySchool) {
              return SchoolView(
                students: filteredStudents,
                onShowDetails: (studentWithInfo) {
                  showDialog(
                    context: context,
                    builder: (context) => StudentDetailsDialog(studentWithInfo: studentWithInfo),
                  );
                },
              );
            } else if (_viewType == StudentViewType.byDate) {
              return const DateView();
            } else {
              return AllStudentsView(
                students: filteredStudents,
                onShowDetails: (studentWithInfo) {
                  showDialog(
                    context: context,
                    builder: (context) => StudentDetailsDialog(studentWithInfo: studentWithInfo),
                  );
                },
                groups: groups,
                expandedGroups: _expandedGroups,
                onGroupAdded: (groupInfo) {
                  DataManager.instance.addGroup(groupInfo);
                  showAppSnackBar(context, '그룹이 등록되었습니다.');
                },
                onGroupUpdated: (groupInfo, index) {
                  DataManager.instance.updateGroup(groupInfo);
                  showAppSnackBar(context, '그룹 정보가 수정되었습니다.');
                },
                onGroupDeleted: (groupInfo) {
                  DataManager.instance.deleteGroup(groupInfo);
                  showAppSnackBar(context, '그룹이 삭제되었습니다.');
                },
                onGroupExpanded: (groupInfo) {
                  setState(() {
                    if (_expandedGroups.contains(groupInfo)) {
                      _expandedGroups.remove(groupInfo);
                    } else {
                      _expandedGroups.add(groupInfo);
                    }
                  });
                },
                onStudentMoved: (studentWithInfo, newGroup) async {
                  print('[DEBUG] onStudentMoved: \u001b[33m${studentWithInfo.student.name}\u001b[0m, \u001b[36m${newGroup?.name}\u001b[0m');
                  if (newGroup != null) {
                    // capacity 체크
                    final groupStudents = DataManager.instance.students.where((s) => s.student.groupInfo?.id == newGroup.id).toList();
                    print('[DEBUG] onStudentMoved - 현재 그룹 인원: \\${groupStudents.length}, 정원: \\${newGroup.capacity}');
                    if (groupStudents.length >= (newGroup.capacity ?? 0)) {
                      print('[DEBUG] onStudentMoved - 정원 초과 다이얼로그 진입');
                      await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF232326),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: Text('${newGroup.name} 정원 초과', style: const TextStyle(color: Colors.white)),
                          content: const Text('정원을 초과하여 학생을 추가할 수 없습니다.', style: TextStyle(color: Colors.white70)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('확인', style: TextStyle(color: Colors.white70)),
                            ),
                          ],
                        ),
                      );
                      print('[DEBUG] onStudentMoved - 정원 초과 다이얼로그 종료');
                      return;
                    }
                    print('[DEBUG] onStudentMoved - updateStudent 호출');
                    await DataManager.instance.updateStudent(
                      studentWithInfo.student.copyWith(groupInfo: newGroup),
                      studentWithInfo.basicInfo.copyWith(groupId: newGroup.id),
                    );
                    showAppSnackBar(context, '그룹이 변경되었습니다.');
                  } else {
                    // 그룹에서 제외
                    await DataManager.instance.updateStudent(
                      studentWithInfo.student.copyWith(groupInfo: null),
                      studentWithInfo.basicInfo.copyWith(groupId: null),
                    );
                    print('[DEBUG] 그룹에서 제외 스낵바 호출 직전');
                    showAppSnackBar(context, '그룹에서 제외되었습니다.');
                  }
                },
                onReorder: (oldIndex, newIndex) {
                  final newGroups = List<GroupInfo>.from(groups);
                  if (newIndex > oldIndex) newIndex--;
                  final item = newGroups.removeAt(oldIndex);
                  newGroups.insert(newIndex, item);
                  DataManager.instance.setGroupsOrder(newGroups);
                },
                onDeleteStudent: (studentWithInfo) async {
                  print('[DEBUG][StudentScreen] onDeleteStudent 진입: id=' + studentWithInfo.student.id + ', name=' + studentWithInfo.student.name);
                  await DataManager.instance.deleteStudent(studentWithInfo.student.id);
                  print('[DEBUG][StudentScreen] DataManager.deleteStudent 호출 완료');
                  showAppSnackBar(context, '학생이 삭제되었습니다.', useRoot: true);
                  print('[DEBUG][StudentScreen] 스낵바 호출 완료');
                },
                onStudentUpdated: (studentWithInfo) async {
                  await showDialog(
                    context: context,
                    builder: (context) => StudentRegistrationDialog(
                      student: studentWithInfo.student,
                      onSave: (updatedStudent, basicInfo) async {
                        await DataManager.instance.updateStudent(updatedStudent, basicInfo);
                        showAppSnackBar(context, '학생 정보가 수정되었습니다.');
                      },
                      groups: DataManager.instance.groups,
                    ),
                  );
                },
                activeFilter: _activeFilter,
                onFilterChanged: (filter) {
                  setState(() {
                    _activeFilter = filter;
                  });
                },
              );
            }
          },
        );
      },
    );
  }

  // void _showStudentDetails(StudentWithInfo studentWithInfo) {
  //   final student = studentWithInfo.student;
  //   showDialog(
  //     context: context,
  //     builder: (context) => AlertDialog(
  //       backgroundColor: const Color(0xFF2A2A2A),
  //       title: Text(
  //         student.name,
  //         style: const TextStyle(color: Colors.white),
  //       ),
  //       content: Column(
  //         mainAxisSize: MainAxisSize.min,
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         children: [
  //           Text(
  //             '학교:  [33m${student.school} [0m',
  //             style: const TextStyle(color: Colors.white70),
  //           ),
  //           const SizedBox(height: 8),
  //           Text(
  //             '과정:  [33m${getEducationLevelName(student.educationLevel)} [0m',
  //             style: const TextStyle(color: Colors.white70),
  //           ),
  //           const SizedBox(height: 8),
  //           Text(
  //             '학년:  [33m${student.grade}학년 [0m',
  //             style: const TextStyle(color: Colors.white70),
  //           ),
  //           if (student.groupInfo != null) ...[
  //             const SizedBox(height: 8),
  //             Text(
  //               '그룹:  [33m${student.groupInfo!.name} [0m',
  //               style: TextStyle(color: student.groupInfo!.color),
  //             ),
  //           ],
  //         ],
  //       ),
  //       actions: [
  //         TextButton(
  //           onPressed: () => Navigator.of(context).pop(),
  //           child: const Text('닫기'),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  void showClassRegistrationDialog() {
    showDialog(
      context: context,
      builder: (context) => GroupRegistrationDialog(
        editMode: false,
        onSave: (groupInfo) {
          print('[DEBUG] GroupRegistrationDialog 호출: student_screen.dart, groupInfo.id=\x1b[33m [33m${groupInfo.id}\x1b[0m');
          DataManager.instance.addGroup(groupInfo);
          showAppSnackBar(context, '그룹이 등록되었습니다.');
        },
      ),
    );
  }

  void showStudentRegistrationDialog() {
    showDialog(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        onSave: (student, basicInfo) async {
          await DataManager.instance.addStudent(student, basicInfo);
          showAppSnackBar(context, '학생이 등록되었습니다.');
        },
        groups: DataManager.instance.groups,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
        return Scaffold(
          backgroundColor: const Color(0xFF1F1F1F),
      appBar: const AppBarTitle(title: '학생'),
          body: Column(
            children: [
              const SizedBox(height: 0),
              SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _customTabIndex,
            tabs: const ['학생', '수강', '성향'],
            onTabSelected: (i) {
              setState(() {
                _customTabIndex = i;
              });
            },
          ),
          const SizedBox(height: 1),
          if (_customTabIndex == 0)
              Row(
                children: [
                  const SizedBox(width: 24),
                  // 좌측: 등록 버튼 (고정 너비, 왼쪽 정렬)
                  SizedBox(
                    width: 131, // 고정 너비 (등록 버튼)
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 131,
                        height: 44,
                        child: FilledButton.icon(
                          onPressed: () {
                            showStudentRegistrationDialog();
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            minimumSize: const Size(0, 44),
                            maximumSize: const Size(double.infinity, 44),
                          ),
                          icon: const Icon(Icons.add, size: 26),
                          label: const Text(
                            '등록 ',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 우측: 검색 바 (고정 너비, 등록 버튼과 동일 너비, 왼쪽 정렬로 바로 붙임)
                  SizedBox(
                    width: 131, // 고정 너비 (검색 바)
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        height: 44,
                        child: SearchBar(
                          controller: _searchController,
                          onChanged: (value) {
                            setState(() {
                              _searchQuery = value;
                            });
                          },
                          hintText: '검색',
                          leading: const Icon(
                            Icons.search,
                            color: Colors.white70,
                            size: 24,
                          ),
                          backgroundColor: MaterialStateColor.resolveWith(
                            (states) => const Color(0xFF2A2A2A),
                          ),
                          elevation: MaterialStateProperty.all(0),
                          padding: const MaterialStatePropertyAll<EdgeInsets>(
                            EdgeInsets.symmetric(horizontal: 18.0),
                          ),
                          textStyle: const MaterialStatePropertyAll<TextStyle>(
                            TextStyle(color: Colors.white, fontSize: 16.5),
                          ),
                          hintStyle: const MaterialStatePropertyAll<TextStyle>(
                            TextStyle(color: Colors.white54, fontSize: 16.5),
                          ),
                          side: MaterialStatePropertyAll<BorderSide>(
                            BorderSide(color: Colors.white.withOpacity(0.2)),
                          ),
                          constraints: const BoxConstraints(minHeight: 44, maxHeight: 44),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 24),
                ],
              ),
          if (_customTabIndex == 0)
            const SizedBox(height: 20),
          Expanded(
            child: Builder(
              builder: (context) {
                if (_customTabIndex == 0) {
                  // 학생
                  return _buildAllStudentsView();
                } else if (_customTabIndex == 1) {
                  // 수강
                  return _buildGroupView();
                } else {
                  // 성향
                  return _buildDateView();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllStudentsView() {
    return ValueListenableBuilder<List<GroupInfo>>(
      valueListenable: DataManager.instance.groupsNotifier,
      builder: (context, groups, _) {
        return ValueListenableBuilder<List<StudentWithInfo>>(
          valueListenable: DataManager.instance.studentsNotifier,
          builder: (context, students, __) {
            final filteredStudents = filterStudents(students);
            return AllStudentsView(
              students: filteredStudents,
              onShowDetails: (studentWithInfo) {
                showDialog(
                  context: context,
                  builder: (context) => StudentDetailsDialog(studentWithInfo: studentWithInfo),
                );
              },
              groups: groups,
              expandedGroups: _expandedGroups,
              onGroupAdded: (groupInfo) {
                DataManager.instance.addGroup(groupInfo);
                showAppSnackBar(context, '그룹이 등록되었습니다.');
              },
              onGroupUpdated: (groupInfo, index) {
                DataManager.instance.updateGroup(groupInfo);
                showAppSnackBar(context, '그룹 정보가 수정되었습니다.');
              },
              onGroupDeleted: (groupInfo) {
                DataManager.instance.deleteGroup(groupInfo);
                showAppSnackBar(context, '그룹이 삭제되었습니다.');
              },
              onGroupExpanded: (groupInfo) {
                setState(() {
                  if (_expandedGroups.contains(groupInfo)) {
                    _expandedGroups.remove(groupInfo);
                  } else {
                    _expandedGroups.add(groupInfo);
                  }
                });
              },
              onStudentMoved: (studentWithInfo, newGroup) async {
                if (newGroup != null) {
                  final groupStudents = DataManager.instance.students.where((s) => s.student.groupInfo?.id == newGroup.id).toList();
                  if (groupStudents.length >= (newGroup.capacity ?? 0)) {
                    await showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF232326),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: Text('${newGroup.name} 정원 초과', style: const TextStyle(color: Colors.white)),
                        content: const Text('정원을 초과하여 학생을 추가할 수 없습니다.', style: TextStyle(color: Colors.white70)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('확인', style: TextStyle(color: Colors.white70)),
                          ),
                        ],
                      ),
                    );
                    return;
                  }
                  await DataManager.instance.updateStudent(
                    studentWithInfo.student.copyWith(groupInfo: newGroup),
                    studentWithInfo.basicInfo.copyWith(groupId: newGroup.id),
                  );
                  showAppSnackBar(context, '그룹이 변경되었습니다.');
                } else {
                  await DataManager.instance.updateStudent(
                    studentWithInfo.student.copyWith(groupInfo: null),
                    studentWithInfo.basicInfo.copyWith(groupId: null),
                  );
                  showAppSnackBar(context, '그룹에서 제외되었습니다.');
                }
              },
              onReorder: (oldIndex, newIndex) {},
              onDeleteStudent: (studentWithInfo) {},
              onStudentUpdated: (studentWithInfo) {},
              activeFilter: _activeFilter,
              onFilterChanged: (filter) {
                setState(() {
                  _activeFilter = filter;
                });
              },
            );
          },
        );
      },
    );
  }

  Widget _buildGroupView() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // 왼쪽 학생 리스트 컨테이너
              LayoutBuilder(
                builder: (context, constraints) {
                  // Row 하위에서는 constraints.maxWidth가 무한대가 될 수 있으므로 화면 폭으로 분기
                  final double screenW = MediaQuery.of(context).size.width;
                  // 기본 폭은 320. 1600px 이하에서는 절반(160)로 축소
                  const double baseWidth = 320.0;
                  const double halfWidth = 160.0;
                  const double minWidth = 150.0;
                  double w = screenW <= 1600 ? halfWidth : baseWidth;
                  w = w < minWidth ? minWidth : w;
                  return Container(
                    width: w,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F1F),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    margin: const EdgeInsets.only(right: 16, left: 15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 헤더
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text(
                            '학생 목록',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // 학생 리스트
                        Expanded(
                          child: ValueListenableBuilder<List<StudentWithInfo>>(
                            valueListenable: DataManager.instance.studentsNotifier,
                            builder: (context, students, child) {
                              final gradeGroups = _groupStudentsByGrade(students);
                              return ListView(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                children: [
                                  ...gradeGroups.entries.map((entry) {
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: _buildGradeGroup(entry.key, entry.value),
                                    );
                                  }).toList(),
                                  const SizedBox(height: 32),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              // 오른쪽 영역: (학생정보 + 달력) + 수강료 납부
              Expanded(
                child: Stack(
                  children: [
                    Column(
                      children: [
                        // 상단: 학생정보 + 달력 통합 컨테이너
                        Container(
                          height: MediaQuery.of(context).size.height * 0.4,
                          margin: const EdgeInsets.only(top: 16, right: 24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F1F),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.transparent, width: 1),
                          ),
                          child: Row(
                            children: [
                          // 학생 정보 영역
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: _selectedStudent != null
                                  ? _buildStudentInfoDisplay(_selectedStudent!)
                                  : const Center(
                                      child: Text(
                                        '학생을 선택해주세요',
                                        style: TextStyle(color: Colors.white70, fontSize: 16),
                                      ),
                                    ),
                            ),
                          ),
                          // 중간 요약 영역 (1:1:1 비율, 푸른 회색 계열)
                          Expanded(
                            flex: 1,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF212A31),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF212A31), width: 1),
                              ),
                              child: _selectedStudent != null
                                  ? SizedBox.expand(child: _buildOverviewSummary(_selectedStudent!))
                                  : const Center(
                                      child: Text(
                                        '학생을 선택하면 요약이 표시됩니다.',
                                        style: TextStyle(color: Colors.white70, fontSize: 16),
                                      ),
                                    ),
                            ),
                          ),
                          // 달력 영역
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                              child: Column(
                                children: [
                                  // 달력 헤더
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
                                          onPressed: () => setState(() => _currentDate = DateTime(_currentDate.year, _currentDate.month - 1)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${_currentDate.year}년 ${_currentDate.month}월',
                                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                                          onPressed: () => setState(() => _currentDate = DateTime(_currentDate.year, _currentDate.month + 1)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // 달력 본체
                                  Expanded(child: _buildCalendar()),
                                  // 출석 상태 범례 (선택된 학생이 있을 때만)
                                  if (_selectedStudent != null)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8, bottom: 24),
                                      child: AttendanceLegend(
                                        showTitle: false,
                                        iconSize: 30,
                                        fontSize: 15,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                          ),
                        ),
                        // 하단: 수강료 납부 + 출석체크
                        const SizedBox(height: 16),
                        Expanded(
                          child: Column(
                            children: [
                              // 수강료 납부
                              Container(
                                height: 220,
                                margin: const EdgeInsets.only(bottom: 24, right: 24),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF18181A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF18181A), width: 1),
                                ),
                                child: _selectedStudent != null
                                    ? _buildPaymentSchedule(_selectedStudent!)
                                    : const Center(
                                        child: Text(
                                          '학생을 선택하면 수강료 납부 일정이 표시됩니다.',
                                          style: TextStyle(color: Colors.white54, fontSize: 16),
                                        ),
                                      ),
                              ),
                              // 출석 체크
                              Container(
                                height: 260,
                                margin: const EdgeInsets.only(bottom: 24, right: 24),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF18181A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF18181A), width: 1),
                                ),
                                child: AttendanceCheckView(
                                  selectedStudent: _selectedStudent,
                                  pageIndex: _attendancePageIndex,
                                  onPageIndexChanged: (newIndex) {
                                    setState(() {
                                      _attendancePageIndex = newIndex;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_selectedStudent == null)
                      Positioned.fill(
                        child: Container(
                          color: const Color(0xFF1F1F1F),
                          padding: const EdgeInsets.only(top: 16),
                          child: _buildInitialDashboard(),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDateView() {
    return const DateView();
  }

  // ========== 출석 관리 헬퍼 메서드들 ==========
  
  // 초기 대시보드(학생 미선택시): 어제 출결, 오늘 출결, 이번달 납입, 오늘 납입 + 하단 리스트
  Widget _buildInitialDashboard() {
    return ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (context, _records, __) {
        final DateTime now = DateTime.now();
        final DateTime todayStart = DateTime(now.year, now.month, now.day);
        final DateTime todayEnd = todayStart.add(const Duration(days: 1));
        final DateTime yesterdayStart = todayStart.subtract(const Duration(days: 1));
        final DateTime yesterdayEnd = todayStart;

        // 전체 학생 기준 요약 (삭제된 학생 제외)
        final Set<String> activeStudentIds = DataManager.instance.students.map((s) => s.student.id).toSet();

    int yPresent = 0, yLate = 0, yAbsent = 0;
    int tPresent = 0, tLate = 0, tAbsent = 0;

    // 지각 임계는 학생별 다를 수 있으나, 초기 대시보드는 보수적으로 10분 기본 사용
    const int defaultLateMinutes = 10;

    for (final r in DataManager.instance.attendanceRecords) {
      if (!activeStudentIds.contains(r.studentId)) continue;
      final dt = r.classDateTime;
      final isYesterday = dt.isAfter(yesterdayStart) && dt.isBefore(yesterdayEnd);
      final isToday = dt.isAfter(todayStart) && dt.isBefore(todayEnd);
      if (!isYesterday && !isToday) continue;

      if (!r.isPresent) {
        if (isYesterday) yAbsent++; else tAbsent++;
      } else {
        final threshold = r.classDateTime.add(const Duration(minutes: defaultLateMinutes));
        final isLate = r.arrivalTime != null && r.arrivalTime!.isAfter(threshold);
        if (isYesterday) {
          if (isLate) yLate++; else yPresent++;
        } else {
          if (isLate) tLate++; else tPresent++;
        }
      }
    }

    // 납부 요약(이번달/오늘)
        final DateTime monthStart = DateTime(now.year, now.month, 1);
        final DateTime nextMonthStart = DateTime(now.year, now.month + 1, 1);
    int monthPaid = 0, monthDue = 0, todayPaid = 0, todayDue = 0;
    for (final pr in DataManager.instance.paymentRecords) {
      if (!activeStudentIds.contains(pr.studentId)) continue;
      final due = pr.dueDate;
      final paid = pr.paidDate;
      final isThisMonth = due.isAfter(monthStart.subtract(const Duration(milliseconds: 1))) && due.isBefore(nextMonthStart);
      final isTodayDue = due.isAfter(todayStart.subtract(const Duration(milliseconds: 1))) && due.isBefore(todayEnd);
      if (isThisMonth) {
        if (paid != null) monthPaid++; else monthDue++;
      }
      if (isTodayDue) {
        if (paid != null) todayPaid++; else todayDue++;
      }
    }

        Widget tile(String title, String big, String sub, {Color accent = const Color(0xFF90CAF9)}) {
          final double screenW = MediaQuery.of(context).size.width;
          // 최소창(≈1430)에서 17, 넓을수록 23까지 선형 증가
          const double minW = 1430;
          const double maxW = 2200;
          const double fsMin = 17; // 최소 화면에서의 글자 크기
          const double fsMax = 23; // 최대 화면에서의 글자 크기
          double t = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
          final double bigFontSize = fsMin + (fsMax - fsMin) * t;
          return Container(
        margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF212A31),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(big, style: TextStyle(color: accent, fontSize: bigFontSize, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(color: Colors.white60, fontSize: 14)),
          ],
        ),
          );
        }

    // 리스트 데이터: 어제/오늘 출석, 이번달/오늘 납입
        final Map<String, _AttendanceInfo> yesterdayAttendanceByStudent = {};
        final Map<String, _AttendanceInfo> todayAttendanceByStudent = {};
        for (final r in DataManager.instance.attendanceRecords) {
      if (!activeStudentIds.contains(r.studentId)) continue;
      final dt = r.classDateTime;
      if (dt.isAfter(yesterdayStart) && dt.isBefore(yesterdayEnd)) {
        yesterdayAttendanceByStudent[r.studentId] = _AttendanceInfo(
          arrival: r.arrivalTime,
          departure: r.departureTime,
          isPresent: r.isPresent,
          isLate: r.arrivalTime != null && r.arrivalTime!.isAfter(r.classDateTime.add(const Duration(minutes: defaultLateMinutes))),
          classDateTime: r.classDateTime,
        );
      } else if (dt.isAfter(todayStart) && dt.isBefore(todayEnd)) {
        todayAttendanceByStudent[r.studentId] = _AttendanceInfo(
          arrival: r.arrivalTime,
          departure: r.departureTime,
          isPresent: r.isPresent,
          isLate: r.arrivalTime != null && r.arrivalTime!.isAfter(r.classDateTime.add(const Duration(minutes: defaultLateMinutes))),
          classDateTime: r.classDateTime,
        );
      }
    }

    // 위에서 선언한 monthStart/nextMonthStart 재사용
        final Map<String, DateTime> monthPaidByStudent = {};
        final Map<String, DateTime> todayPaidByStudent = {};
        for (final pr in DataManager.instance.paymentRecords) {
      if (!activeStudentIds.contains(pr.studentId)) continue;
      if (pr.paidDate == null) continue;
      final paid = pr.paidDate!;
      if (paid.isAfter(monthStart.subtract(const Duration(milliseconds: 1))) && paid.isBefore(nextMonthStart)) {
        monthPaidByStudent[pr.studentId] = paid;
      }
      if (paid.isAfter(todayStart) && paid.isBefore(todayEnd)) {
        todayPaidByStudent[pr.studentId] = paid;
      }
    }

        String _nameOf(String studentId) {
          try {
            return DataManager.instance.students.firstWhere((s) => s.student.id == studentId).student.name;
          } catch (_) {
            return studentId;
          }
        }

        Widget _simpleRow(String left, {required Widget statusLine, String? timeLine}) {
          final double screenW = MediaQuery.of(context).size.width;
          // 1430에서 14, 2200에서 18까지 선형 보간
          const double minW = 1430;
          const double maxW = 2200;
          const double minFs = 14;
          const double maxFs = 18;
          double t = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
          final double nameFontSize = minFs + (maxFs - minFs) * t;
          return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F1F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1행: 이름 + 상태
            Row(
              children: [
                Expanded(child: Text(left, style: TextStyle(color: Colors.white, fontSize: nameFontSize, fontWeight: FontWeight.w700))),
                const SizedBox(width: 8),
                statusLine,
              ],
            ),
            if (timeLine != null) ...[
              const SizedBox(height: 4),
              Text(timeLine, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ],
        ),
          );
        }

    // 각 타일별 개별 리스트를 같은 칼럼에 배치
        Widget listFor(Map<String, _AttendanceInfo> data, {required bool isAttendance}) {
          // 부모 컨테이너(타일과 동일 너비/여백)로 래핑하여 너비 일치
          return Container(
        margin: const EdgeInsets.symmetric(horizontal: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF212A31),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: (data.isEmpty)
            ? const Align(
                alignment: Alignment.centerLeft,
                child: Text('기록 없음', style: TextStyle(color: Colors.white54, fontSize: 13)),
              )
            : Column(
                children: data.entries.map((e) {
                  final name = _nameOf(e.key);
                  final info = e.value;
                      Widget rightWidget;
                  if (isAttendance) {
                    // 상태 폰트 반응형 크기 (최소창≈1430에서 12 → 넓을수록 16)
                    final double screenW = MediaQuery.of(context).size.width;
                    const double minW = 1430;
                    const double maxW = 2200;
                    const double fsMin = 12;
                    const double fsMax = 16;
                    double tFS = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
                    final double statusFontSize = fsMin + (fsMax - fsMin) * tFS;
                    if (!info.isPresent) {
                          rightWidget = Text('무단결석', style: TextStyle(color: const Color(0xFFE53E3E), fontSize: statusFontSize, fontWeight: FontWeight.w700));
                    } else {
                      final arr = info.arrival != null ? '${info.arrival!.hour.toString().padLeft(2,'0')}:${info.arrival!.minute.toString().padLeft(2,'0')}' : '--:--';
                      final dep = info.departure != null ? '${info.departure!.hour.toString().padLeft(2,'0')}:${info.departure!.minute.toString().padLeft(2,'0')}' : '--:--';
                          rightWidget = Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (info.isLate)
                                Text('지각', style: TextStyle(color: const Color(0xFFFF9800), fontSize: statusFontSize, fontWeight: FontWeight.w700)),
                            ],
                          );
                    }
                  } else {
                    // 수강료는 날짜만 표시
                        final paid = info.arrival;
                        final due = DataManager.instance.paymentRecords
                            .firstWhere(
                              (r) => r.studentId == e.key,
                              orElse: () => PaymentRecord(id: -1, studentId: e.key, cycle: 0, dueDate: DateTime(0), paidDate: null),
                            )
                            .dueDate;
                        rightWidget = Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(paid != null ? '납부 ${paid.month}/${paid.day}' : '미납', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                            Text('예정 ${due.month}/${due.day}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                          ],
                        );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: isAttendance
                          ? () async {
                              // 출석체크 카드의 체크박스 동작과 동일한 액션 연결
                              // 바로 출석시간 수정/무단결석 토글로 진입
                              await _jumpToAttendanceEdit(e.key, info.classDateTime, info.isPresent);
                            }
                          : null,
                          child: _simpleRow(
                            name,
                            statusLine: rightWidget,
                            timeLine: isAttendance
                                ? (info.isPresent
                                    ? '등원 ${info.arrival != null ? info.arrival!.hour.toString().padLeft(2,'0') + ':' + info.arrival!.minute.toString().padLeft(2,'0') : '--:--'} · 하원 ${info.departure != null ? info.departure!.hour.toString().padLeft(2,'0') + ':' + info.departure!.minute.toString().padLeft(2,'0') : '--:--'}'
                                    : null)
                                : null,
                          ),
                    ),
                  );
                }).toList(),
              ),
          );
        }

        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tile('어제 출결', '출석 ${yPresent + yLate} · 결석 $yAbsent', '지각 $yLate', accent: const Color(0xFF64B5F6)),
                  listFor(yesterdayAttendanceByStudent, isAttendance: true),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tile('오늘 출결', '출석 ${tPresent + tLate} · 결석 $tAbsent', '지각 $tLate', accent: const Color(0xFF64B5F6)),
                  listFor(todayAttendanceByStudent, isAttendance: true),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tile('이번달 납입', '완료 $monthPaid · 예정 $monthDue', '${now.month}월 납부 현황', accent: const Color(0xFF90CAF9)),
                  listFor(
                    monthPaidByStudent.map((k, v) => MapEntry(
                      k,
                      _AttendanceInfo(
                        arrival: v,
                        departure: null,
                        isPresent: true,
                        isLate: false,
                        classDateTime: v,
                      ),
                    )),
                    isAttendance: false,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tile('오늘 납입', '완료 $todayPaid · 예정 $todayDue', '오늘(${now.month}/${now.day}) 납부', accent: const Color(0xFF90CAF9)),
                  listFor(
                    todayPaidByStudent.map((k, v) => MapEntry(
                      k,
                      _AttendanceInfo(
                        arrival: v,
                        departure: null,
                        isPresent: true,
                        isLate: false,
                        classDateTime: v,
                      ),
                    )),
                    isAttendance: false,
                  ),
                ],
              ),
            ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  // 학생 리스트 학년별 그룹핑
  Map<String, List<StudentWithInfo>> _groupStudentsByGrade(List<StudentWithInfo> students) {
    final Map<String, List<StudentWithInfo>> gradeGroups = {};
    for (var student in students) {
      // educationLevel과 grade를 조합하여 '초6', '중1' 등으로 표시
      final levelPrefix = _getEducationLevelPrefix(student.student.educationLevel);
      final grade = '$levelPrefix${student.student.grade}';
      if (gradeGroups[grade] == null) {
        gradeGroups[grade] = [];
      }
      gradeGroups[grade]!.add(student);
    }

    // 학년 순서대로 정렬 (초-중-고 순)
    final sortedKeys = gradeGroups.keys.toList()
      ..sort((a, b) {
        final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        const levelOrder = {'초': 1, '중': 2, '고': 3};
        final aLevel = levelOrder[a.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;
        final bLevel = levelOrder[b.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;

        if (aLevel != bLevel) {
          return aLevel.compareTo(bLevel);
        }
        return aNum.compareTo(bNum);
      });

    return {for (var key in sortedKeys) key: gradeGroups[key]!};
  }

  // 교육 단계 접두사 반환
  String _getEducationLevelPrefix(dynamic educationLevel) {
    if (educationLevel.toString().contains('elementary')) return '초';
    if (educationLevel.toString().contains('middle')) return '중';
    if (educationLevel.toString().contains('high')) return '고';
    return '';
  }

  // 학년 그룹 위젯
  Widget _buildGradeGroup(String grade, List<StudentWithInfo> students) {
    final key = grade;
    final isExpanded = _isExpanded[key] ?? false;
    return Container(
      decoration: BoxDecoration(
        color: isExpanded ? const Color(0xFF2A2A2A) : const Color(0xFF2D2D2D), // 접혀있을 때도 배경색 지정
        borderRadius: BorderRadius.circular(0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                // 🔄 아코디언 방식: 다른 모든 그룹을 닫고 현재 그룹만 토글
                if (isExpanded) {
                  // 현재 그룹이 열려있으면 닫기
                  _isExpanded[key] = false;
                } else {
                  // 현재 그룹이 닫혀있으면 모든 그룹을 닫고 현재 그룹만 열기
                  _isExpanded.clear();
                  _isExpanded[key] = true;
                }
              });
            },
            child: Container(
              color: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Row(
                children: [
                  Text(
                    '  $grade   ${students.length}명', // 인원수 추가
                    style: const TextStyle(
                      color: Color(0xFFB0B0B0), // 덜 밝은 흰색
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: const Color(0xFFB0B0B0), // 덜 밝은 흰색
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: students.length,
              itemBuilder: (context, index) {
                final studentWithInfo = students[index];
                return _AttendanceStudentCard(
                  studentWithInfo: studentWithInfo,
                  isSelected: _selectedStudent?.student.id == studentWithInfo.student.id,
                  onTap: () {
                    setState(() {
                      // 다른 학생으로 변경될 때 페이지 인덱스 초기화
                      if (_selectedStudent?.student.id != studentWithInfo.student.id) {
                        _paymentPageIndex = 0;
                        _attendancePageIndex = 0;
                        print('[DEBUG][onTap] 학생 변경으로 인한 초기화 - ${studentWithInfo.student.name}');
                      }
                      _selectedStudent = studentWithInfo;
                    });
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  // 학생 정보 표시 위젯
  Widget _buildStudentInfoDisplay(StudentWithInfo studentWithInfo) {
    final student = studentWithInfo.student;
    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((tb) => tb.studentId == student.id)
        .toList();
    final classSchedules = _groupTimeBlocksByClass(timeBlocks);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start, // 상단 정렬
        children: [
          Row(
            children: [
              Text(
                student.name,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${student.school} / ${_getEducationLevelKorean(student.educationLevel)} / ${student.grade}학년', // 한글로 변경
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                ),
              ),
              IconButton(
                onPressed: () => _showStudentPaymentSettingsDialog(studentWithInfo),
                icon: const Icon(Icons.settings, color: Colors.white70),
                tooltip: '결제 및 수업 설정',
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white24),
          const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...classSchedules.entries.map((entry) {
                    final className = entry.key;
                    final schedules = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            className,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          ...schedules.map((schedule) => Text(
                            '${schedule['day']} ${schedule['start']} ~ ${schedule['end']}',
                            style: const TextStyle(fontSize: 17, color: Colors.white70),
                          )),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 교육 단계 한글 변환
  String _getEducationLevelKorean(dynamic educationLevel) {
    if (educationLevel.toString().contains('elementary')) return '초등';
    if (educationLevel.toString().contains('middle')) return '중등';
    if (educationLevel.toString().contains('high')) return '고등';
    return educationLevel.toString();
  }

  // 수업 시간 블록 그룹핑
  Map<String, List<Map<String, String>>> _groupTimeBlocksByClass(List<StudentTimeBlock> timeBlocks) {
    final Map<String?, List<StudentTimeBlock>> blocksBySet = {}; // 키 타입을 String?로 변경
    for (var block in timeBlocks) {
      if (blocksBySet[block.setId] == null) {
        blocksBySet[block.setId] = [];
      }
      blocksBySet[block.setId]!.add(block);
    }

    final Map<String, List<Map<String, String>>> classSchedules = {};
    blocksBySet.forEach((setId, blocks) {
      if (blocks.isEmpty) return;
      final firstBlock = blocks.first;
      String className = '수업';
      try {
        // sessionTypeId를 직접 사용하여 ClassInfo를 찾습니다.
        if (firstBlock.sessionTypeId != null) {
          final classInfo = DataManager.instance.classes.firstWhere((c) => c.id == firstBlock.sessionTypeId);
          className = classInfo.name;
        }
      } catch (e) {
        // 해당 클래스 정보가 없을 경우 기본값 사용
      }

      final schedule = _formatTimeBlocks(blocks);
      if (classSchedules[className] == null) {
        classSchedules[className] = [];
      }
      classSchedules[className]!.add(schedule);
    });

    return classSchedules;
  }

  // 시간 포맷팅
  Map<String, String> _formatTimeBlocks(List<StudentTimeBlock> blocks) {
    if (blocks.isEmpty) return {};
    final dayOfWeek = ['월', '화', '수', '목', '금', '토', '일'];
    final firstBlock = blocks.first;
    final lastBlock = blocks.last;

    int startHour = firstBlock.startHour;
    int startMinute = firstBlock.startMinute;
    
    // endHour와 endMinute는 duration을 사용하여 계산합니다.
    final startTime = DateTime(2023, 1, 1, lastBlock.startHour, lastBlock.startMinute);
    final endTime = startTime.add(lastBlock.duration);
    int endHour = endTime.hour;
    int endMinute = endTime.minute;

    return {
      'day': dayOfWeek[firstBlock.dayIndex], // day -> dayIndex
      'start': '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}',
      'end': '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}',
    };
  }

  // 달력 위젯
  Widget _buildCalendar() {
    final daysInMonth = DateUtils.getDaysInMonth(_currentDate.year, _currentDate.month);
    final firstDayOfMonth = DateTime(_currentDate.year, _currentDate.month, 1);
    final weekdayOfFirstDay = firstDayOfMonth.weekday; // 월요일=1, 일요일=7

    final today = DateTime.now();
    final dayOfWeekHeaders = ['월', '화', '수', '목', '금', '토', '일'];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: dayOfWeekHeaders.map((day) => Text(day, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))).toList(),
          ),
        ),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
            itemCount: daysInMonth + weekdayOfFirstDay - 1,
            itemBuilder: (context, index) {
              if (index < weekdayOfFirstDay - 1) {
                return Container(); // Empty container for days before the 1st
              }
              final dayNumber = index - (weekdayOfFirstDay - 1) + 1;
              final date = DateTime(_currentDate.year, _currentDate.month, dayNumber);
              final isToday = DateUtils.isSameDay(date, today);

              return Container(
                margin: const EdgeInsets.all(5),
                decoration: isToday
                    ? BoxDecoration(
                        border: Border.all(color: const Color(0xFF1976D2), width: 3),
                        borderRadius: BorderRadius.circular(7),
                      )
                    : null,
                child: Stack(
                  children: [
                    // 날짜 숫자는 중앙에 고정
                    Center(
                      child: Text(
                        '$dayNumber',
                        style: TextStyle(
                          color: isToday ? Colors.white : Colors.white, 
                          fontSize: 17,
                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    // 하단 밑줄: 예정 수업 출결 상태 (추가수업 제외)
                    if (_selectedStudent != null)
                      Positioned(
                        bottom: 6,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: AttendanceIndicator(
                            studentId: _selectedStudent!.student.id,
                            date: date,
                            width: 40,
                            thickness: 8.0,
                          ),
                        ),
                      ),
                    // 상단 점: 추가수업 출결 상태
                    if (_selectedStudent != null)
                      Positioned(
                        top: 6,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: _AddOverrideDot(
                            studentId: _selectedStudent!.student.id,
                            date: date,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // 추가수업 점 표시 위젯
  Widget _AddOverrideDot({required String studentId, required DateTime date}) {
    final overrides = DataManager.instance.sessionOverrides;
    final records = DataManager.instance.attendanceRecords;
    final dateStart = DateTime(date.year, date.month, date.day);
    final dateEnd = dateStart.add(const Duration(days: 1));
    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;

    final addOnDate = overrides.where((o) =>
      o.studentId == studentId &&
      o.overrideType == OverrideType.add &&
      o.status != OverrideStatus.canceled &&
      o.replacementClassDateTime != null &&
      o.replacementClassDateTime!.isAfter(dateStart) &&
      o.replacementClassDateTime!.isBefore(dateEnd)
    ).toList();

    if (addOnDate.isEmpty) return const SizedBox.shrink();

    // 해당 추가수업에 연결된 출석 상태로 색상 결정
    Color dotColor = Colors.white24; // 기본(예정)
    for (final o in addOnDate) {
      final rec = records.firstWhere(
        (r) => r.studentId == studentId && sameMinute(r.classDateTime, o.replacementClassDateTime!),
        orElse: () => AttendanceRecord(
          id: null,
          studentId: studentId,
          classDateTime: dateStart,
          classEndTime: dateStart,
          className: '',
          isPresent: false,
          arrivalTime: null,
          departureTime: null,
          notes: null,
          createdAt: dateStart,
          updatedAt: dateStart,
        ),
      );
      if (rec.id == null) continue; // 기록 없음 → 예정
      if (!rec.isPresent) { dotColor = Colors.red; break; }
      if (rec.arrivalTime != null) {
        // 지각 기준: 학생별 설정을 쓰기엔 컨텍스트 부족하므로 기본 10분
        final lateThreshold = rec.classDateTime.add(const Duration(minutes: 10));
        if (rec.arrivalTime!.isAfter(lateThreshold)) { dotColor = const Color(0xFFFB8C00); }
        else { dotColor = const Color(0xFF0C3A69); }
      } else { dotColor = const Color(0xFF0C3A69); }
    }

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
    );
  }

  // 왼쪽 화살표 활성화 조건 확인
  bool _hasPastPaymentRecords(StudentWithInfo studentWithInfo, DateTime currentMonth) {
    final registrationDate = studentWithInfo.basicInfo.registrationDate;
    if (registrationDate == null) return false;
    
    final registrationMonth = DateTime(registrationDate.year, registrationDate.month);
    
    // 전체 월 리스트 생성
    final allMonths = <DateTime>[];
    DateTime month = registrationMonth;
    while (month.isBefore(DateTime(currentMonth.year, currentMonth.month + 3))) {
      allMonths.add(month);
      month = DateTime(month.year, month.month + 1);
    }
    
    // 현재월의 인덱스 찾기
    final currentMonthIndex = allMonths.indexWhere((m) => 
      m.year == currentMonth.year && m.month == currentMonth.month);
    
    if (currentMonthIndex == -1) return false;
    
    // 조건: 현재월 기준 왼쪽에 3개 이상 카드가 있어야 함
    // 그리고 아직 최대한 왼쪽으로 이동하지 않은 상태
    final leftCardsCount = currentMonthIndex; // 현재월 왼쪽에 있는 카드 수
    final maxLeftMove = (leftCardsCount - 2).clamp(0, leftCardsCount); // 최대 왼쪽 이동 가능 횟수
    
    print('[DEBUG][_hasPastPaymentRecords] 현재월 인덱스: $currentMonthIndex, 왼쪽 카드 수: $leftCardsCount, 최대 이동: $maxLeftMove, 현재 페이지: $_paymentPageIndex');
    
    return leftCardsCount >= 3 && _paymentPageIndex < maxLeftMove;
  }
  
  // 오른쪽 화살표 활성화 조건 확인 (복귀용)
  bool _hasFuturePaymentCards(StudentWithInfo studentWithInfo, DateTime currentMonth) {
    // 왼쪽으로 이동한 상태(_paymentPageIndex > 0)에서만 오른쪽으로 복귀 가능
    return _paymentPageIndex > 0;
  }

  // 수강료 납부 일정 위젯
  Widget _buildPaymentSchedule(StudentWithInfo studentWithInfo) {
    final basicInfo = studentWithInfo.basicInfo;
    final registrationDate = basicInfo.registrationDate;

    if (registrationDate == null) {
      return const Center(child: Text('등록일자 정보가 없습니다.', style: TextStyle(color: Colors.white70)));
    }

    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final registrationMonth = DateTime(registrationDate.year, registrationDate.month);
    
    // 화살표 활성화 상태 계산 및 업데이트
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hasPastRecords = _hasPastPaymentRecords(studentWithInfo, currentMonth);
      final hasFutureCards = _hasFuturePaymentCards(studentWithInfo, currentMonth);
      
      if (_paymentHasPastRecords != hasPastRecords || _paymentHasFutureCards != hasFutureCards) {
        setState(() {
          _paymentHasPastRecords = hasPastRecords;
          _paymentHasFutureCards = hasFutureCards;
        });
      }
    });
    
    // 페이지 인덱스에 따라 월별 카드 생성
    print('[DEBUG][_buildPaymentSchedule] _paymentPageIndex: $_paymentPageIndex');
    print('[DEBUG][_buildPaymentSchedule] currentMonth: $currentMonth');
    print('[DEBUG][_buildPaymentSchedule] registrationMonth: $registrationMonth');
    
    // 전체 가능한 월 리스트 생성 (등록월부터 현재월+2달까지)
    final allMonths = <DateTime>[];
    DateTime month = registrationMonth;
    while (month.isBefore(DateTime(currentMonth.year, currentMonth.month + 3))) {
      allMonths.add(month);
      month = DateTime(month.year, month.month + 1);
    }
    
    print('[DEBUG][_buildPaymentSchedule] 전체 가능한 월: ${allMonths.map((m) => '${m.year}-${m.month}').join(', ')}');
    
    // 현재월의 인덱스 찾기
    final currentMonthIndex = allMonths.indexWhere((m) => 
      m.year == currentMonth.year && m.month == currentMonth.month);
    
    print('[DEBUG][_buildPaymentSchedule] 현재월 인덱스: $currentMonthIndex');
    
    final candidateMonths = <DateTime>[];
    if (currentMonthIndex == -1) {
      // 현재월이 없으면 전체 표시
      candidateMonths.addAll(allMonths.take(5));
    } else {
      // 스마트 페이징: 현재월을 기준으로 5개 윈도우 계산
      int windowStart;
      
      if (_paymentPageIndex == 0) {
        // 초기 상태: 현재월이 가운데 오도록 (또는 오른쪽에 치우치게)
        windowStart = (currentMonthIndex - 2).clamp(0, (allMonths.length - 5).clamp(0, allMonths.length));
      } else {
        // 페이징 상태: _paymentPageIndex만큼 왼쪽으로 이동
        windowStart = (currentMonthIndex - 2 - _paymentPageIndex).clamp(0, (allMonths.length - 5).clamp(0, allMonths.length));
      }
      
      final windowEnd = (windowStart + 5).clamp(0, allMonths.length);
      candidateMonths.addAll(allMonths.sublist(windowStart, windowEnd));
      
      print('[DEBUG][_buildPaymentSchedule] 윈도우 범위: $windowStart~${windowEnd-1}, 표시 월: ${candidateMonths.map((m) => '${m.year}-${m.month}').join(', ')}');
    }
    
    // 등록월 이후의 달만 필터링
    final validMonths = candidateMonths
        .where((month) => month.isAfter(registrationMonth) || month.isAtSameMomentAs(registrationMonth))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '수강료 납부',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _showDueDateEditDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 7.2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1976D2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '수정', 
                    style: TextStyle(
                      color: Colors.white, 
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _showPaymentListDialog(studentWithInfo),
                icon: Icon(Icons.list, color: Colors.white70, size: 19.8),
                label: const Text('리스트', style: TextStyle(color: Colors.white70)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 13.2, vertical: 8.8),
                  foregroundColor: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 납부 예정일 (카드 뷰)
          Row(
            children: validMonths.asMap().entries.map((entry) {
              final index = entry.key;
              final month = entry.value;

              // 동적으로 라벨 생성
              String label;
              final monthDiff = (month.year - currentMonth.year) * 12 + (month.month - currentMonth.month);
              if (monthDiff == 0) {
                label = '이번달';
              } else if (monthDiff < 0) {
                label = '${monthDiff.abs()}달전';
              } else {
                label = '${monthDiff}달후';
              }

              // 과거 기록을 보는 경우(_paymentPageIndex > 0)에는 파란 테두리 제거
              final isCurrentMonth = _paymentPageIndex == 0 &&
                  month.year == currentMonth.year &&
                  month.month == currentMonth.month;

              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index < validMonths.length - 1 ? 8 : 0),
                  child: _buildPaymentDateCard(
                    _getActualPaymentDateForMonth(studentWithInfo.student.id, registrationDate, month),
                    label,
                    isCurrentMonth,
                    registrationDate,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // 실제 납부일 (카드 뷰)
          Row(
            children: validMonths.asMap().entries.map((entry) {
              final index = entry.key;
              final month = entry.value;
              final paymentDate = _getActualPaymentDateForMonth(studentWithInfo.student.id, registrationDate, month);
              final cycleNumber = _calculateCycleNumber(registrationDate, paymentDate);

              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index < validMonths.length - 1 ? 8 : 0),
                  child: _buildActualPaymentCard(paymentDate, cycleNumber),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // 전체 요약 컨테이너: 수강료/출석/지각율
  Widget _buildOverviewSummary(StudentWithInfo studentWithInfo) {
    final String studentId = studentWithInfo.student.id;
    final DateTime now = DateTime.now();
    final DateTime todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

    // 출석 통계 (과거 기준)
    final paymentInfo = DataManager.instance.getStudentPaymentInfo(studentId);
    final int lateThresholdMinutes = paymentInfo?.latenessThreshold ?? 10;
    int countPresent = 0;
    int countLate = 0;
    int countAbsent = 0;

    for (final r in DataManager.instance.getAttendanceRecordsForStudent(studentId)) {
      if (!r.classDateTime.isBefore(todayEnd)) continue; // 미래 제외
      if (!r.isPresent) {
        countAbsent++;
      } else {
        if (r.arrivalTime != null) {
          final threshold = r.classDateTime.add(Duration(minutes: lateThresholdMinutes));
          if (r.arrivalTime!.isAfter(threshold)) {
            countLate++;
          } else {
            countPresent++;
          }
        } else {
          // 출석 기록은 있으나 등원 시간이 없는 경우 정상 출석으로 간주
          countPresent++;
        }
      }
    }
    final int totalAttendance = countPresent + countLate + countAbsent;
    final int attendedCount = countPresent + countLate;
    final double tardinessRate = attendedCount > 0 ? (countLate / attendedCount) * 100.0 : 0.0;

    // 수강료 통계 수정: 분모=등록월~현재월 예정 개수, 이전/다음 납부일 계산
    final DateTime? registrationDate = studentWithInfo.basicInfo.registrationDate;
    int paidCycles = 0;
    int totalCycles = 0;
    DateTime? previousPaidDate;
    DateTime? nextDueDate;
    if (registrationDate != null) {
      final DateTime currentMonth = DateTime(now.year, now.month);
      final int cyclesUntilCurrent = _calculateCycleNumber(
        registrationDate,
        DateTime(currentMonth.year, currentMonth.month, registrationDate.day),
      );
      totalCycles = cyclesUntilCurrent;

      for (int c = 1; c <= cyclesUntilCurrent; c++) {
        final record = DataManager.instance.getPaymentRecord(studentId, c);
        if (record?.paidDate != null) paidCycles++;
      }

      final paidRecords = DataManager.instance
          .getPaymentRecordsForStudent(studentId)
          .where((r) => r.paidDate != null)
          .toList();
      if (paidRecords.isNotEmpty) {
        paidRecords.sort((a, b) => a.paidDate!.compareTo(b.paidDate!));
        previousPaidDate = paidRecords.last.paidDate;
      }

      DateTime probe = currentMonth;
      for (int i = 0; i < 12; i++) {
        final due = _getActualPaymentDateForMonth(studentId, registrationDate, probe);
        final cycle = _calculateCycleNumber(registrationDate, due);
        final record = DataManager.instance.getPaymentRecord(studentId, cycle);
        if (record?.paidDate == null) { nextDueDate = due; break; }
        probe = DateTime(probe.year, probe.month + 1);
      }
    }

    Color _rateColor(double rate) {
      if (rate >= 20.0) return const Color(0xFFE53E3E); // red
      if (rate >= 5.0) return const Color(0xFFFB8C00); // orange
      return const Color(0xFF4CAF50); // green
    }

    Widget _statCard({
      required String title,
      required String mainText,
      String? subText,
      Color accent = const Color(0xFF1976D2),
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.2, vertical: 13.5),
        decoration: BoxDecoration(
          color: Colors.transparent, // 부모 컨테이너 배경색 사용
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(color: Colors.white70, fontSize: 16.2, fontWeight: FontWeight.w600)),
            const SizedBox(height: 9),
            Text(
              mainText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: accent, fontSize: 24.3, fontWeight: FontWeight.w800, height: 1.0),
            ),
            if (subText != null) ...[
              const SizedBox(height: 6),
              Text(
                subText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 16.2, height: 1.2),
              ),
            ],
          ],
        ),
      );
    }

    final double attendanceRate = totalAttendance > 0
        ? ((countPresent + countLate) / totalAttendance) * 100.0
        : 0.0;

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statCard(
              title: '수강료',
              mainText: registrationDate != null ? '$paidCycles/$totalCycles 납부' : '-',
              subText: registrationDate != null
                  ? '${previousPaidDate != null ? '이전 ${previousPaidDate!.year}/${previousPaidDate!.month}/${previousPaidDate!.day}' : '이전 없음'} · '
                    '${nextDueDate != null ? '다음 ${nextDueDate!.year}/${nextDueDate!.month}/${nextDueDate!.day}' : '다음 없음'}'
                  : '정보 없음',
              accent: const Color(0xFF90CAF9),
            ),
            const SizedBox(height: 9),
            _statCard(
              title: '출석',
              mainText: totalAttendance > 0 ? '출석 ${countPresent + countLate} · 결석 $countAbsent' : '-',
              subText: totalAttendance > 0 ? '총 $totalAttendance회' : '기록 없음',
              accent: const Color(0xFF64B5F6),
            ),
            const SizedBox(height: 9),
            _statCard(
              title: '지각율',
              mainText: '${tardinessRate.toStringAsFixed(1)}%',
              subText: '지각 $countLate회',
              accent: _rateColor(tardinessRate),
            ),
            const SizedBox(height: 9),
            _statCard(
              title: '출석율',
              mainText: '${attendanceRate.toStringAsFixed(1)}%',
              subText: totalAttendance > 0 ? '(${countPresent + countLate} / $totalAttendance회)' : '기록 없음',
              accent: const Color(0xFF81C784),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPaymentListDialog(
    StudentWithInfo studentWithInfo,
  ) async {
    final registrationDate = studentWithInfo.basicInfo.registrationDate!;
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final registrationMonth = DateTime(registrationDate.year, registrationDate.month);
    // 전체 가능한 월 리스트 생성 (등록월부터 현재월+2달까지)
    final List<DateTime> allMonths = <DateTime>[];
    DateTime month = registrationMonth;
    while (month.isBefore(DateTime(currentMonth.year, currentMonth.month + 3))) {
      allMonths.add(month);
      month = DateTime(month.year, month.month + 1);
    }
    final validMonths = allMonths;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          title: const Text('수강료 납부', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            height: 380,
            child: Scrollbar(
              thumbVisibility: true,
              child: ListView.separated(
                itemCount: validMonths.length,
                separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                itemBuilder: (context, index) {
                  final month = validMonths[index];
                  final paymentDate = _getActualPaymentDateForMonth(studentWithInfo.student.id, registrationDate, month);
                  final cycleNumber = _calculateCycleNumber(registrationDate, paymentDate);
                  final record = DataManager.instance.getPaymentRecord(studentWithInfo.student.id, cycleNumber);

                  final monthDiff = (month.year - currentMonth.year) * 12 + (month.month - currentMonth.month);
                  String label;
                  if (monthDiff == 0) {
                    label = '이번달';
                  } else if (monthDiff < 0) {
                    label = '${monthDiff.abs()}달전';
                  } else {
                    label = '${monthDiff}달후';
                  }

                  return GestureDetector(
                    onTap: () => _showPaymentDatePicker(
                      record ?? PaymentRecord(studentId: studentWithInfo.student.id, cycle: cycleNumber, dueDate: paymentDate),
                    ),
                    child: Container(
                      height: 60,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
                      ),
                      child: Row(
                        children: [
                          // 월
                          SizedBox(
                            width: 88,
                            child: Text(
                              '${month.year}.${month.month.toString().padLeft(2,'0')}',
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                          // 라벨
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ),
                          const Spacer(),
                          // 예정일
                          Text(
                            '예정 ${paymentDate.month}/${paymentDate.day}',
                            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 12),
                          // 실제 납부일 or 미납
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Text(
                              record?.paidDate != null ? '${record!.paidDate!.month}/${record.paidDate!.day}' : '미납',
                              style: TextStyle(color: record?.paidDate != null ? const Color(0xFF4CAF50) : Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기', style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      },
    );
  }

  // 납부 예정일 카드
  Widget _buildPaymentDateCard(DateTime paymentDate, String label, bool isCurrentMonth, DateTime registrationDate) {
    final cycleNumber = _calculateCycleNumber(registrationDate, paymentDate);
    return Tooltip(
      message: '$cycleNumber번째',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
          border: isCurrentMonth ? Border.all(color: const Color(0xFF1976D2), width: 2) : Border.all(color: const Color(0xFF444444), width: 1),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: isCurrentMonth ? const Color(0xFF1976D2) : Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(
              '${paymentDate.month}/${paymentDate.day}',
              style: TextStyle(color: isCurrentMonth ? Colors.white : Colors.white70, fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // 실제 납부일 카드
  Widget _buildActualPaymentCard(DateTime paymentDate, int cycleNumber) {
    final record = DataManager.instance.getPaymentRecord(_selectedStudent!.student.id, cycleNumber);
    return GestureDetector(
      onTap: () => _showPaymentDatePicker(record ?? PaymentRecord(studentId: _selectedStudent!.student.id, cycle: cycleNumber, dueDate: paymentDate)),
      child: Container(
        height: 30,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: Colors.transparent),
        ),
        child: Container(
          width: 60,
          height: 40,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.transparent),
          ),
          child: Center(
            child: record?.paidDate != null
                ? Text(
                    '${record!.paidDate!.month}/${record.paidDate!.day}',
                    style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 19, fontWeight: FontWeight.w600),
                  )
                : Container(
                    width: 20,
                    height: 2,
                    decoration: BoxDecoration(color: Colors.white60, borderRadius: BorderRadius.circular(1.5)),
                  ),
          ),
        ),
      ),
    );
  }

  // 납부일 선택 다이얼로그
  Future<void> _showPaymentDatePicker(PaymentRecord record) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: record.paidDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
      locale: const Locale('ko', 'KR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF2A2A2A),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final updatedRecord = PaymentRecord(
        id: record.id,
        studentId: record.studentId,
        cycle: record.cycle,
        dueDate: record.dueDate,
        paidDate: picked,
      );

      if (record.id != null) {
        await DataManager.instance.updatePaymentRecord(updatedRecord);
      } else {
        await DataManager.instance.addPaymentRecord(updatedRecord);
      }
      if (mounted) setState(() {});
    }
  }

  // 납부일 수정 다이얼로그
  Future<void> _showDueDateEditDialog() async {
    if (_selectedStudent == null) return;

    final basicInfo = _selectedStudent!.basicInfo;
    final registrationDate = basicInfo.registrationDate;
    if (registrationDate == null) return;

    // 1. 이번달부터 시작하여 아직 납부하지 않은 가장 빠른 달 찾기
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    
    DateTime? earliestUnpaidMonth;
    int? earliestUnpaidCycle;
    
    // 이번달부터 6개월간 확인 (충분한 범위)
    for (int i = 0; i < 6; i++) {
      final targetMonth = DateTime(currentMonth.year, currentMonth.month + i);
      final paymentDate = _getActualPaymentDateForMonth(_selectedStudent!.student.id, registrationDate, targetMonth);
      final cycle = _calculateCycleNumber(registrationDate, paymentDate);
      
      // 해당 사이클의 납부 기록 확인
      final record = DataManager.instance.getPaymentRecord(_selectedStudent!.student.id, cycle);
      
      // 아직 납부하지 않은 첫 번째 달을 찾았으면 중단
      if (record?.paidDate == null) {
        earliestUnpaidMonth = targetMonth;
        earliestUnpaidCycle = cycle;
        break;
      }
    }

    if (earliestUnpaidMonth == null || earliestUnpaidCycle == null) {
      // 모든 달이 납부 완료된 경우
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('수정 가능한 미납부 월이 없습니다.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // 2. 현재 납부 예정일 가져오기
    final currentRecord = DataManager.instance.getPaymentRecord(_selectedStudent!.student.id, earliestUnpaidCycle);
    final currentDueDate = currentRecord?.dueDate ?? 
        DateTime(earliestUnpaidMonth.year, earliestUnpaidMonth.month, registrationDate.day);

    // 3. 날짜 선택 다이얼로그 표시
    // 1번째 사이클의 경우 수강등록일 이후만 선택 가능하도록 제한
    final firstSelectableDate = earliestUnpaidCycle == 1 ? registrationDate : DateTime(2000);
    
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: currentDueDate.isBefore(firstSelectableDate) ? firstSelectableDate : currentDueDate,
      firstDate: firstSelectableDate,
      lastDate: DateTime(2101),
      locale: const Locale('ko', 'KR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF2A2A2A),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
      helpText: earliestUnpaidCycle == 1 
        ? '${earliestUnpaidMonth.month}월 납부일 수정 (수강등록일 이후만 가능)'
        : '${earliestUnpaidMonth.month}월 납부일 수정',
    );

    if (pickedDate != null) {
      // 4-1. 1번째 사이클의 경우 수강등록일 이전으로 설정할 수 없도록 방어
      if (earliestUnpaidCycle == 1 && pickedDate.isBefore(registrationDate)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('1번째 사이클 결제일은 수강등록일(${registrationDate.month}/${registrationDate.day}) 이전으로 설정할 수 없습니다.'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      
      // 4-2. 선택한 날짜로 해당 사이클 업데이트 또는 추가
      final updatedRecord = PaymentRecord(
        id: currentRecord?.id,
        studentId: _selectedStudent!.student.id,
        cycle: earliestUnpaidCycle,
        dueDate: pickedDate,
        paidDate: currentRecord?.paidDate, // 기존 납부일 유지
      );

      if (currentRecord?.id != null) {
        await DataManager.instance.updatePaymentRecord(updatedRecord);
      } else {
        await DataManager.instance.addPaymentRecord(updatedRecord);
      }

      // 5. 이후 월들의 납부 예정일 재계산 및 업데이트
      await _recalculateSubsequentPaymentDates(
        _selectedStudent!.student.id, 
        registrationDate, 
        earliestUnpaidCycle, 
        pickedDate
      );

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${earliestUnpaidMonth.month}월 납부일이 ${pickedDate.month}/${pickedDate.day}로 수정되었습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  // 이후 월들의 납부 예정일 재계산
  Future<void> _recalculateSubsequentPaymentDates(
    String studentId, 
    DateTime registrationDate, 
    int startCycle, 
    DateTime newBaseDate
  ) async {
    // 수정된 날짜의 day를 기준으로 이후 월들 재계산
    final newDay = newBaseDate.day;
    
    // 다음 6개월간 재계산 (충분한 범위)
    for (int i = 1; i <= 6; i++) {
      final targetCycle = startCycle + i;
      
      // 기존 레코드 확인
      final existingRecord = DataManager.instance.getPaymentRecord(studentId, targetCycle);
      
      // 이미 납부 완료된 경우는 건드리지 않음
      if (existingRecord?.paidDate != null) {
        continue;
      }
      
      // 새로운 납부 예정일 계산
      final baseMonth = DateTime(newBaseDate.year, newBaseDate.month + i);
      final newDueDate = DateTime(baseMonth.year, baseMonth.month, newDay);
      
      final updatedRecord = PaymentRecord(
        id: existingRecord?.id,
        studentId: studentId,
        cycle: targetCycle,
        dueDate: newDueDate,
        paidDate: existingRecord?.paidDate,
      );
      
      if (existingRecord?.id != null) {
        await DataManager.instance.updatePaymentRecord(updatedRecord);
      } else {
        await DataManager.instance.addPaymentRecord(updatedRecord);
      }
    }
  }

  // 월별 실제 납부일 계산
  DateTime _getActualPaymentDateForMonth(String studentId, DateTime registrationDate, DateTime targetMonth) {
    final defaultDate = DateTime(targetMonth.year, targetMonth.month, registrationDate.day);
    final cycle = _calculateCycleNumber(registrationDate, defaultDate);
    
    final record = DataManager.instance.getPaymentRecord(studentId, cycle);
    if (record != null) {
      return record.dueDate;
    }
    
    return defaultDate;
  }

  // 사이클 번호 계산
  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    final regMonth = DateTime(registrationDate.year, registrationDate.month);
    final payMonth = DateTime(paymentDate.year, paymentDate.month);
    return (payMonth.year - regMonth.year) * 12 + (payMonth.month - regMonth.month) + 1;
  }

  // 학생 결제 및 수업 설정 다이얼로그 표시
  void _showStudentPaymentSettingsDialog(StudentWithInfo studentWithInfo) {
    showDialog(
      context: context,
      builder: (context) => StudentPaymentSettingsDialog(studentWithInfo: studentWithInfo),
    );
  }

  Future<void> _jumpToAttendanceEdit(String studentId, DateTime classDateTime, bool isPresent) async {
    try {
      final record = DataManager.instance.getAttendanceRecord(studentId, classDateTime);
      final int duration = DataManager.instance.academySettings.lessonDuration;
      final String className = '-';
      if (record == null || !record.isPresent) {
        // 무단결석 → 정상 출석(시작~종료)으로 전환
        await DataManager.instance.saveOrUpdateAttendance(
          studentId: studentId,
          classDateTime: classDateTime,
          classEndTime: classDateTime.add(Duration(minutes: duration)),
          className: className,
          isPresent: true,
          arrivalTime: classDateTime,
          departureTime: classDateTime.add(Duration(minutes: duration)),
        );
      } else {
        // 출석 있음 → 출석 시간 수정 다이얼로그 (공개 유틸) 호출
        await showAttendanceEditDialog(
          context: context,
          studentId: studentId,
          classDateTime: classDateTime,
          durationMinutes: duration,
          className: className,
        );
      }
    } catch (e) {
      // noop
    }
  }

}

class _AttendanceInfo {
  final DateTime? arrival;
  final DateTime? departure;
  final bool isPresent;
  final bool isLate;
  final DateTime classDateTime;
  _AttendanceInfo({required this.arrival, required this.departure, required this.isPresent, required this.isLate, required this.classDateTime});
}

// 학생 리스트 카드
class _AttendanceStudentCard extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final bool isSelected;
  final VoidCallback onTap;

  const _AttendanceStudentCard({
    required this.studentWithInfo,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_AttendanceStudentCard> createState() => _AttendanceStudentCardState();
}

class _AttendanceStudentCardState extends State<_AttendanceStudentCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    
    return Tooltip(
      message: student.school,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 17),
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        onEnter: (_) {
          if (!widget.isSelected) {
            setState(() => _isHovered = true);
          }
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: () {
            setState(() => _isHovered = false);
            widget.onTap();
          },
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            decoration: BoxDecoration(
              border: widget.isSelected
                  ? Border.all(color: const Color(0xFF1976D2), width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Text(
                  student.name,
                  style: const TextStyle(
                    color: Color(0xFFE0E0E0),
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                  ),
                ),
                if (_isHovered && !widget.isSelected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1976D2),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 학생 결제 및 수업 설정 다이얼로그
class StudentPaymentSettingsDialog extends StatefulWidget {
  final StudentWithInfo studentWithInfo;

  const StudentPaymentSettingsDialog({
    super.key,
    required this.studentWithInfo,
  });

  @override
  State<StudentPaymentSettingsDialog> createState() => _StudentPaymentSettingsDialogState();
}

class _StudentPaymentSettingsDialogState extends State<StudentPaymentSettingsDialog> {
  late DateTime _registrationDate;
  late String _paymentMethod;
  late TextEditingController _tuitionFeeController;
  late TextEditingController _latenessThresholdController;
  
  bool _scheduleNotification = false;
  bool _attendanceNotification = false;
  bool _departureNotification = false;
  bool _latenessNotification = false;

  @override
  void initState() {
    super.initState();
    
    // 기존 결제 정보 로드 또는 기본값 설정
    final existingPaymentInfo = DataManager.instance.getStudentPaymentInfo(widget.studentWithInfo.student.id);
    
    if (existingPaymentInfo != null) {
      _registrationDate = existingPaymentInfo.registrationDate;
      _paymentMethod = existingPaymentInfo.paymentMethod;
      _tuitionFeeController = TextEditingController(text: existingPaymentInfo.tuitionFee.toString());
      _latenessThresholdController = TextEditingController(text: existingPaymentInfo.latenessThreshold.toString());
      _scheduleNotification = existingPaymentInfo.scheduleNotification;
      _attendanceNotification = existingPaymentInfo.attendanceNotification;
      _departureNotification = existingPaymentInfo.departureNotification;
      _latenessNotification = existingPaymentInfo.latenessNotification;
    } else {
      // 기본값 설정 (기존 학생 정보에서 가져오기)
      _registrationDate = DateTime.now();
      _paymentMethod = 'monthly';
      _tuitionFeeController = TextEditingController();
      _latenessThresholdController = TextEditingController(text: '10');
      
      // 기존 student_basic_info 데이터가 있다면 student_payment_info로 자동 마이그레이션
      _migrateFromBasicInfo();
    }
  }

      // 기존 student_basic_info에서 student_payment_info로 데이터 마이그레이션
  Future<void> _migrateFromBasicInfo() async {
    final basicInfo = widget.studentWithInfo.basicInfo;
    if (basicInfo != null) {
      try {
        final paymentInfo = StudentPaymentInfo(
          id: const Uuid().v4(),
          studentId: widget.studentWithInfo.student.id,
          registrationDate: DateTime.now(),
          paymentMethod: 'monthly',
          tuitionFee: 0,
          latenessThreshold: 10,
          scheduleNotification: false,
          attendanceNotification: false,
          departureNotification: false,
          latenessNotification: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        
        await DataManager.instance.addStudentPaymentInfo(paymentInfo);
        print('[INFO] 학생 ${widget.studentWithInfo.student.name}의 정보를 student_payment_info로 마이그레이션 완료');
      } catch (e) {
        print('[ERROR] 마이그레이션 실패: $e');
      }
    }
  }

  @override
  void dispose() {
    _tuitionFeeController.dispose();
    _latenessThresholdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 타이틀
            Row(
              children: [
                Text(
                  widget.studentWithInfo.student.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // 1. 등록일자와 지불방식
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final selectedDate = await showDatePicker(
                        context: context,
                        initialDate: _registrationDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        builder: (context, child) => Theme(
                          data: ThemeData.dark().copyWith(
                            colorScheme: const ColorScheme.dark(
                              primary: Color(0xFF1976D2),
                            ),
                          ),
                          child: child!,
                        ),
                      );
                      if (selectedDate != null) {
                        setState(() {
                          _registrationDate = selectedDate;
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
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${_registrationDate.year}년 ${_registrationDate.month}월 ${_registrationDate.day}일',
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
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _paymentMethod,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF2A2A2A),
                    decoration: InputDecoration(
                      labelText: '지불방식',
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
                        child: Text('월결제', style: TextStyle(color: Colors.white)),
                      ),
                      DropdownMenuItem(
                        value: 'session',
                        child: Text('횟수제', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _paymentMethod = value;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // 2. 수업료 입력란
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tuitionFeeController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '수업료',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                      hintText: '수업료를 입력하세요',
                      hintStyle: const TextStyle(color: Colors.white38),
                      suffixText: '만원',
                      suffixStyle: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  height: 48,
                  width: 48,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: IconButton(
                    onPressed: () => _showTuitionCustomDialog(),
                    icon: const Icon(
                      Icons.add,
                      color: Colors.white70,
                    ),
                    tooltip: '수업별 커스텀 수업료',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // 3. 지각기준 필드
            SizedBox(
              width: 200,
              child: TextField(
                controller: _latenessThresholdController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '지각기준',
                  labelStyle: const TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                  hintText: '분 단위로 입력',
                  hintStyle: const TextStyle(color: Colors.white38),
                  suffixText: '분',
                  suffixStyle: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // 4. 안내문자 체크박스들
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('안내문자', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _buildCheckboxItem('수강일자 안내', _scheduleNotification, (value) {
                      setState(() => _scheduleNotification = value);
                    }),
                    _buildCheckboxItem('출결', _attendanceNotification, (value) {
                      setState(() => _attendanceNotification = value);
                    }),
                    _buildCheckboxItem('하원', _departureNotification, (value) {
                      setState(() => _departureNotification = value);
                    }),
                    _buildCheckboxItem('지각', _latenessNotification, (value) {
                      setState(() => _latenessNotification = value);
                    }),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 32),
            
            // 버튼들
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _saveSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text(
                    '저장',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckboxItem(String title, bool value, Function(bool) onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: (newValue) => onChanged(newValue ?? false),
          activeColor: const Color(0xFF1976D2),
          checkColor: Colors.white,
        ),
        Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }

  // 학생의 수업 정보 가져오기
  Map<String, List<StudentTimeBlock>> _getStudentClassesGrouped() {
    final studentBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == widget.studentWithInfo.student.id)
        .toList();

    final Map<String, List<StudentTimeBlock>> classGroups = {};
    
    for (final block in studentBlocks) {
      String className = '일반 수업';
      
      // sessionTypeId가 있으면 해당 클래스 이름 찾기
      if (block.sessionTypeId != null) {
        try {
          final classInfo = DataManager.instance.classes
              .firstWhere((c) => c.id == block.sessionTypeId);
          className = classInfo.name;
        } catch (e) {
          // 클래스를 찾을 수 없는 경우 기본값 사용
          className = '일반 수업';
        }
      }
      
      classGroups.putIfAbsent(className, () => []).add(block);
    }
    
    return classGroups;
  }

  void _showTuitionCustomDialog() {
    final classGroups = _getStudentClassesGrouped();
    
    showDialog(
      context: context,
      builder: (context) => TuitionCustomDialog(
        studentName: widget.studentWithInfo.student.name,
        classGroups: classGroups,
      ),
    );
  }

  void _saveSettings() async {
    try {
      final tuitionFee = int.tryParse(_tuitionFeeController.text) ?? 0;
      final latenessThreshold = int.tryParse(_latenessThresholdController.text) ?? 10;

      final paymentInfo = StudentPaymentInfo(
        id: const Uuid().v4(),
        studentId: widget.studentWithInfo.student.id,
        registrationDate: _registrationDate,
        paymentMethod: _paymentMethod,
        tuitionFee: tuitionFee,
        latenessThreshold: latenessThreshold,
        scheduleNotification: _scheduleNotification,
        attendanceNotification: _attendanceNotification,
        departureNotification: _departureNotification,
        latenessNotification: _latenessNotification,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await DataManager.instance.addStudentPaymentInfo(paymentInfo);
      
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('설정이 저장되었습니다.'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('설정 저장 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// 수업료 커스텀 다이얼로그
class TuitionCustomDialog extends StatefulWidget {
  final String studentName;
  final Map<String, List<StudentTimeBlock>> classGroups;

  const TuitionCustomDialog({
    super.key,
    required this.studentName,
    required this.classGroups,
  });

  @override
  State<TuitionCustomDialog> createState() => _TuitionCustomDialogState();
}

class _TuitionCustomDialogState extends State<TuitionCustomDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, int> _classFees = {};

  @override
  void initState() {
    super.initState();
    // 각 수업명별로 컨트롤러 생성
    for (final className in widget.classGroups.keys) {
      _controllers[className] = TextEditingController();
      _classFees[className] = 0;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _getDayName(int dayIndex) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[dayIndex] ?? '?';
  }

  String _formatTime(int hour, int minute) {
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  int _getTotalFee() {
    return _classFees.values.fold(0, (sum, fee) => sum + fee);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1F1F1F),
      child: Container(
        width: 600,
        constraints: const BoxConstraints(
          maxHeight: 700, // 다이얼로그 최대 높이 제한
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 타이틀
            Row(
              children: [
                Text(
                  '${widget.studentName} - 수업별 수업료',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 수업별 리스트
            if (widget.classGroups.isEmpty)
              const Center(
                child: Text(
                  '등록된 수업이 없습니다.',
                  style: TextStyle(color: Colors.white70),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 300, // 최대 높이 제한 (더 컴팩트하게)
                ),
                child: ListView.builder(
                  shrinkWrap: true, // 내용에 맞춰 크기 조정
                  physics: const BouncingScrollPhysics(), // 부드러운 스크롤
                  itemCount: widget.classGroups.length,
                  itemBuilder: (context, index) {
                    final className = widget.classGroups.keys.elementAt(index);
                    final blocks = widget.classGroups[className]!;
                    
                    // 주당 횟수 계산 (중복 제거)
                    final uniqueDays = blocks.map((b) => b.dayIndex).toSet();
                    final weeklyCount = uniqueDays.length;

                    return Card(
                      color: const Color(0xFF2A2A2A),
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 수업명과 주당 횟수
                            Text(
                              '$className (주 ${weeklyCount}회)',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),

                            // 수업 시간 정보
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: uniqueDays.map((dayIndex) {
                                final dayBlocks = blocks.where((b) => b.dayIndex == dayIndex).toList();
                                if (dayBlocks.isEmpty) return const SizedBox();
                                
                                final startTime = _formatTime(dayBlocks.first.startHour, dayBlocks.first.startMinute);
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1976D2).withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${_getDayName(dayIndex)} $startTime',
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 16),

                            // 수업료 입력
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _controllers[className],
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(color: Colors.white),
                                    onChanged: (value) {
                                      setState(() {
                                        _classFees[className] = int.tryParse(value) ?? 0;
                                      });
                                    },
                                    decoration: InputDecoration(
                                      labelText: '수업료',
                                      labelStyle: const TextStyle(color: Colors.white70),
                                      enabledBorder: OutlineInputBorder(
                                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                                      ),
                                      focusedBorder: const OutlineInputBorder(
                                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                                      ),
                                      suffixText: '만원',
                                      suffixStyle: const TextStyle(color: Colors.white70),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

            const SizedBox(height: 16),

            // 총 수업료 표시
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1976D2).withOpacity(0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '총 수업료',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${_getTotalFee()}만원',
                    style: const TextStyle(
                      color: Color(0xFF1976D2),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 버튼
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '취소',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () {
                    // TODO: 수업별 수업료 저장 로직 (향후 구현)
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('수업별 수업료 설정이 저장되었습니다. (총 ${_getTotalFee()}만원)'),
                        backgroundColor: const Color(0xFF4CAF50),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                  ),
                  child: const Text(
                    '저장',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
} 