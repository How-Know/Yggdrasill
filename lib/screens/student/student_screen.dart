import 'package:flutter/material.dart';
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

  // 출석 관리 관련 상태 변수들
  StudentWithInfo? _selectedStudent;
  final Map<String, bool> _isExpanded = {};
  DateTime _currentDate = DateTime.now();
  DateTime _currentCalendarDate = DateTime.now();
  int _prevTabIndex = 0;

  late Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _loadData();
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadGroups();
    await DataManager.instance.loadStudents();
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
                  showAppSnackBar(context, '학생이 삭제되었습니다.');
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
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 131,
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
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 220,
                            child: SearchBar(
                              controller: _searchController,
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                });
                              },
                              hintText: '학생 검색',
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
                              hintStyle: MaterialStatePropertyAll<TextStyle>(
                                TextStyle(color: Colors.white54, fontSize: 16.5),
                              ),
                              side: MaterialStatePropertyAll<BorderSide>(
                                BorderSide(color: Colors.white.withOpacity(0.2)),
                              ),
                              constraints: const BoxConstraints(
                                minHeight: 44,
                                maxHeight: 44,
                              ),
                            ),
                          ),
                          const SizedBox(width: 24),
                        ],
                      ),
                    ),
                  ),
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
              Container(
                width: 260,
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
              ),
              // 오른쪽 영역: (학생정보 + 달력) + 수강료 납부
              Expanded(
                child: Column(
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
                          // 중간 요약 영역
                          Expanded(
                            flex: 1,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF212A31),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF212A31), width: 1),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Center(
                                  child: Text(
                                    '전체 요약',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
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
                          AttendanceCheckView(
                            selectedStudent: _selectedStudent,
                          ),
                          const SizedBox(height: 16),
                        ],
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
              Text(
                '${student.school} / ${_getEducationLevelKorean(student.educationLevel)} / ${student.grade}학년', // 한글로 변경
                style: const TextStyle(fontSize: 16, color: Colors.white70),
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
                child: Center(
                  child: Text(
                    '$dayNumber',
                    style: TextStyle(
                      color: isToday ? Colors.white : Colors.white, 
                      fontSize: 17,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
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
    
    // 등록일 이후의 달만 포함하도록 수정
    final candidateMonths = [
      DateTime(currentMonth.year, currentMonth.month - 2),
      DateTime(currentMonth.year, currentMonth.month - 1),
      currentMonth,
      DateTime(currentMonth.year, currentMonth.month + 1),
      DateTime(currentMonth.year, currentMonth.month + 2),
    ];
    
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
              const SizedBox(width: 16),
              GestureDetector(
                onTap: _showDueDateEditDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1976D2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '수정', 
                    style: TextStyle(
                      color: Colors.white, 
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 납부 예정일
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
              
              final isCurrentMonth = month.year == currentMonth.year && month.month == currentMonth.month;

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
          // 실제 납부일
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
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: currentDueDate,
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
      helpText: '${earliestUnpaidMonth.month}월 납부일 수정',
    );

    if (pickedDate != null) {
      // 4. 선택한 날짜로 해당 사이클 업데이트 또는 추가
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