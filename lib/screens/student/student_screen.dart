import 'package:flutter/material.dart';
import '../../models/student.dart';
import '../../models/group_info.dart';
import '../../models/student_view_type.dart';
import '../../models/education_level.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_registration_dialog.dart';
import '../../widgets/class_registration_dialog.dart';
import 'components/all_students_view.dart';
import 'components/group_view.dart';
import 'components/school_view.dart';
import 'components/date_view.dart';
import '../../widgets/app_bar_title.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../widgets/custom_tab_bar.dart';
import 'package:flutter/foundation.dart';

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
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Student> filterStudents(List<Student> students) {
    if (_searchQuery.isEmpty) return students;
    return students.where((student) =>
      student.name.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  Widget _buildContent() {
    return ValueListenableBuilder<List<GroupInfo>>(
      valueListenable: DataManager.instance.groupsNotifier,
      builder: (context, groups, _) {
        return ValueListenableBuilder<List<Student>>(
          valueListenable: DataManager.instance.studentsNotifier,
          builder: (context, students, __) {
            final filteredStudents = filterStudents(students);
            if (_viewType == StudentViewType.byClass) {
              return GroupView(
                groups: groups,
                students: students,
                expandedGroups: _expandedGroups,
                onGroupExpanded: (groupInfo) {
                  setState(() {
                    if (_expandedGroups.contains(groupInfo)) {
                      _expandedGroups.remove(groupInfo);
                    } else {
                      _expandedGroups.add(groupInfo);
                    }
                  });
                },
                onGroupUpdated: (groupInfo, index) {
                  DataManager.instance.updateGroup(groupInfo);
                },
                onGroupDeleted: (groupInfo) {
                  DataManager.instance.deleteGroup(groupInfo);
                },
                onStudentMoved: (student, newGroup) {
                  DataManager.instance.updateStudent(student.copyWith(groupInfo: newGroup));
                },
              );
            } else if (_viewType == StudentViewType.bySchool) {
              return SchoolView(
                students: filteredStudents,
                onShowDetails: _showStudentDetails,
              );
            } else if (_viewType == StudentViewType.byDate) {
              return const DateView();
            } else {
              return AllStudentsView(
                students: filteredStudents,
                onShowDetails: _showStudentDetails,
                groups: groups,
                expandedGroups: _expandedGroups,
                onGroupAdded: (groupInfo) {
                  DataManager.instance.addGroup(groupInfo);
                },
                onGroupUpdated: (groupInfo, index) {
                  DataManager.instance.updateGroup(groupInfo);
                },
                onGroupDeleted: (groupInfo) {
                  DataManager.instance.deleteGroup(groupInfo);
                },
                onStudentMoved: (student, newGroup) {
                  DataManager.instance.updateStudent(student.copyWith(groupInfo: newGroup));
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
                onReorder: (oldIndex, newIndex) {
                  final newGroups = List<GroupInfo>.from(groups);
                  if (newIndex > oldIndex) newIndex--;
                  final item = newGroups.removeAt(oldIndex);
                  newGroups.insert(newIndex, item);
                  DataManager.instance.saveGroups();
                },
                onDeleteStudent: (student) async {
                  await DataManager.instance.deleteStudent(student.id);
                },
                onStudentUpdated: (updatedStudent) async {
                  await DataManager.instance.updateStudent(updatedStudent);
                },
              );
            }
          },
        );
      },
    );
  }

  void _showStudentDetails(Student student) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          student.name,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '학교: ${student.school}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              '과정: ${getEducationLevelName(student.educationLevel)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              '학년: ${student.grade}학년',
              style: const TextStyle(color: Colors.white70),
            ),
            if (student.groupInfo != null) ...[
              const SizedBox(height: 8),
              Text(
                '그룹: ${student.groupInfo!.name}',
                style: TextStyle(color: student.groupInfo!.color),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  void showClassRegistrationDialog() {
    showDialog(
      context: context,
      builder: (context) => GroupRegistrationDialog(
        editMode: false,
        onSave: (groupInfo) {
          DataManager.instance.addGroup(groupInfo);
        },
      ),
    );
  }

  void showStudentRegistrationDialog() {
    showDialog(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        onSave: (student) async {
          await DataManager.instance.addStudent(student);
        },
        groups: DataManager.instance.groups,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Scaffold(
          backgroundColor: const Color(0xFF1F1F1F),
          appBar: AppBarTitle(
            title: '학생',
            onBack: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            onForward: () {
              // 윈도우/모바일에서는 특별한 동작 없음
            },
            onRefresh: () => setState(() {}),
          ),
          body: Column(
            children: [
              const SizedBox(height: 0),
              CustomTabBar(
                selectedIndex: _customTabIndex,
                tabs: const ['학생 정보', '수강 일자'],
                onTabSelected: (idx) => setState(() {
                  _prevTabIndex = _customTabIndex;
                  _customTabIndex = idx;
                  if (idx == 0) {
                    _viewType = StudentViewType.all;
                  } else if (idx == 1) {
                    _viewType = StudentViewType.byDate;
                  }
                }),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 24),
                  if (_viewType != StudentViewType.byClass)
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
                            '등록',
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
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: _buildContent(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
} 