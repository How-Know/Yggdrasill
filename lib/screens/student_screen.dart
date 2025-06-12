import 'package:flutter/material.dart';
import '../models/student.dart';
import '../widgets/student_card.dart';
import '../widgets/student_registration_dialog.dart';
import '../widgets/student_details_dialog.dart';

enum StudentViewType {
  all,
  byClass,
  bySchool,
  byDate,
}

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key});

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  StudentViewType _viewType = StudentViewType.all;
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<Student> get filteredStudents {
    if (_searchQuery.isEmpty) return _students;
    return _students.where((student) {
      final name = student.name.toLowerCase();
      final school = student.school.toLowerCase();
      final query = _searchQuery.toLowerCase();
      return name.contains(query) || school.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          const Center(
            child: Text(
              '학생',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              // Left Section
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 120,
                    child: FilledButton.icon(
                      onPressed: () => _showStudentRegistrationDialog(null),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      icon: const Icon(Icons.add, size: 24),
                      label: const Text(
                        '등록',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Center Section - Segmented Button
              Expanded(
                flex: 2,
                child: Center(
                  child: SizedBox(
                    width: 500,
                    child: SegmentedButton<StudentViewType>(
                      segments: const [
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.all,
                          label: Text('모든 학생'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.byClass,
                          label: Text('클래스'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.bySchool,
                          label: Text('학교별'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.byDate,
                          label: Text('수강 일자'),
                        ),
                      ],
                      selected: {_viewType},
                      onSelectionChanged: (Set<StudentViewType> newSelection) {
                        setState(() {
                          _viewType = newSelection.first;
                        });
                      },
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return const Color(0xFF1CB1F5).withOpacity(0.4);
                            }
                            return Colors.transparent;
                          },
                        ),
                        foregroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return Colors.white;
                            }
                            return Colors.white70;
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Right Section
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 240,
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
                      ),
                      backgroundColor: MaterialStateColor.resolveWith(
                        (states) => const Color(0xFF2A2A2A),
                      ),
                      elevation: MaterialStateProperty.all(0),
                      padding: const MaterialStatePropertyAll<EdgeInsets>(
                        EdgeInsets.symmetric(horizontal: 16.0),
                      ),
                      textStyle: const MaterialStatePropertyAll<TextStyle>(
                        TextStyle(color: Colors.white),
                      ),
                      hintStyle: MaterialStatePropertyAll<TextStyle>(
                        TextStyle(color: Colors.white.withOpacity(0.5)),
                      ),
                      side: MaterialStatePropertyAll<BorderSide>(
                        BorderSide(color: Colors.white.withOpacity(0.2)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_viewType) {
      case StudentViewType.byClass:
        return _buildClassView();
      case StudentViewType.bySchool:
        return _buildSchoolView();
      case StudentViewType.byDate:
        return _buildDateView();
      default:
        return _buildAllStudentsView();
    }
  }

  Widget _buildSchoolView() {
    final Map<EducationLevel, Map<String, List<Student>>> groupedStudents = {
      EducationLevel.elementary: <String, List<Student>>{},
      EducationLevel.middle: <String, List<Student>>{},
      EducationLevel.high: <String, List<Student>>{},
    };

    for (final student in filteredStudents) {
      final level = student.educationLevel;
      final school = student.school;
      if (groupedStudents[level]![school] == null) {
        groupedStudents[level]![school] = [];
      }
      groupedStudents[level]![school]!.add(student);
    }

    for (final level in groupedStudents.keys) {
      final schoolMap = groupedStudents[level]!;
      for (final students in schoolMap.values) {
        students.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30.0, 24.0, 30.0, 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildEducationLevelSchoolGroup('초등', EducationLevel.elementary, groupedStudents),
              if (groupedStudents[EducationLevel.elementary]!.isNotEmpty &&
                  (groupedStudents[EducationLevel.middle]!.isNotEmpty ||
                   groupedStudents[EducationLevel.high]!.isNotEmpty))
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('중등', EducationLevel.middle, groupedStudents),
              if (groupedStudents[EducationLevel.middle]!.isNotEmpty &&
                  groupedStudents[EducationLevel.high]!.isNotEmpty)
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('고등', EducationLevel.high, groupedStudents),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEducationLevelSchoolGroup(
    String levelTitle,
    EducationLevel level,
    Map<EducationLevel, Map<String, List<Student>>> groupedStudents,
  ) {
    final schoolMap = groupedStudents[level]!;
    if (schoolMap.isEmpty) return const SizedBox.shrink();

    final sortedSchools = schoolMap.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Text(
            levelTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        for (final school in sortedSchools) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(
              school,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white70,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24.0),
            child: Wrap(
              alignment: WrapAlignment.start,
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
                for (final student in schoolMap[school]!)
                  StudentCard(
                    student: student,
                    width: 220,
                    onEdit: _showStudentRegistrationDialog,
                    onDelete: _showDeleteConfirmationDialog,
                    onShowDetails: _showStudentDetails,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDateView() {
    return Container();
  }

  Widget _buildAllStudentsView() {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in filteredStudents) {
      groupedStudents[student.educationLevel]![student.grade.value] ??= [];
      groupedStudents[student.educationLevel]![student.grade.value]!.add(student);
    }

    for (final level in groupedStudents.keys) {
      for (final gradeStudents in groupedStudents[level]!.values) {
        gradeStudents.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30.0, 24.0, 30.0, 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildEducationLevelGroup('초등', EducationLevel.elementary, groupedStudents),
              const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelGroup('중등', EducationLevel.middle, groupedStudents),
              const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelGroup('고등', EducationLevel.high, groupedStudents),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEducationLevelGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<int, List<Student>>> groupedStudents,
  ) {
    final students = groupedStudents[level]!;
    final totalCount = students.values.fold<int>(0, (sum, list) => sum + list.length);

    final List<Widget> gradeWidgets = students.entries
        .where((entry) => entry.value.isNotEmpty)
        .map<Widget>((entry) {
          final gradeStudents = entry.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(
                  '${entry.key}학년',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: gradeStudents.map((student) => StudentCard(
                  student: student,
                  width: 220,
                  onEdit: _showStudentRegistrationDialog,
                  onDelete: _showDeleteConfirmationDialog,
                  onShowDetails: _showStudentDetails,
                )).toList(),
              ),
            ],
          );
        })
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$totalCount명',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...gradeWidgets,
      ],
    );
  }

  Widget _buildClassView() {
    // TODO: 클래스별 보기 구현
    return const Center(
      child: Text(
        '클래스별 보기 준비 중...',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }

  void _showStudentDetails(Student student) {
    showDialog(
      context: context,
      builder: (context) => StudentDetailsDialog(student: student),
    );
  }

  Future<void> _showDeleteConfirmationDialog(Student student) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text(
          '학생 삭제',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '정말 이 학생을 삭제하시겠습니까?',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              '취소',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _students.remove(student);
      });
    }
  }

  void _showStudentRegistrationDialog(Student? student) {
    showDialog(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        editingStudent: student,
        onSave: (updatedStudent) {
          setState(() {
            if (student != null) {
              final index = _students.indexOf(student);
              if (index != -1) {
                _students[index] = updatedStudent;
              }
            } else {
              _students.add(updatedStudent);
            }
          });
        },
      ),
    );
  }
} 