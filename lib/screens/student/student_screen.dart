import 'package:flutter/material.dart';
import '../../models/student.dart';
import '../../models/class_info.dart';
import '../../models/student_view_type.dart';
import '../../models/education_level.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_registration_dialog.dart';
import '../../widgets/class_registration_dialog.dart';
import 'components/all_students_view.dart';
import 'components/class_view.dart';
import 'components/school_view.dart';
import 'components/date_view.dart';

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key});

  @override
  State<StudentScreen> createState() => StudentScreenState();
}

class StudentScreenState extends State<StudentScreen> {
  StudentViewType get viewType => _viewType;
  StudentViewType _viewType = StudentViewType.all;
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<ClassInfo> _expandedClasses = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _classes.clear();
      _classes.addAll(DataManager.instance.classes);
      _students.clear();
      _students.addAll(DataManager.instance.students);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Student> get filteredStudents {
    if (_searchQuery.isEmpty) return _students;
    return _students.where((student) =>
      student.name.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  Widget _buildContent() {
    if (_viewType == StudentViewType.byClass) {
      return ClassView(
        classes: _classes,
        students: _students,
        expandedClasses: _expandedClasses,
        onClassExpanded: (classInfo) {
          setState(() {
            if (_expandedClasses.contains(classInfo)) {
              _expandedClasses.remove(classInfo);
            } else {
              _expandedClasses.add(classInfo);
            }
          });
        },
        onClassUpdated: (classInfo, index) {
          setState(() {
            _classes[index] = classInfo;
            DataManager.instance.updateClass(classInfo);
          });
        },
        onClassDeleted: (classInfo) {
          setState(() {
            _classes.remove(classInfo);
            DataManager.instance.deleteClass(classInfo);
          });
        },
        onStudentMoved: (student, newClass) {
          setState(() {
            final index = _students.indexOf(student);
            if (index != -1) {
              _students[index] = student.copyWith(classInfo: newClass);
            }
          });
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
      );
    }
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
            if (student.classInfo != null) ...[
              const SizedBox(height: 8),
              Text(
                '클래스: ${student.classInfo!.name}',
                style: TextStyle(color: student.classInfo!.color),
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
      builder: (context) => ClassRegistrationDialog(
        editMode: false,
        onSave: (classInfo) {
          setState(() {
            _classes.add(classInfo);
            DataManager.instance.addClass(classInfo);
          });
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
          setState(() {
            _initializeData();
          });
        },
        classes: DataManager.instance.classes,
      ),
    );
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
                      onPressed: () {
                        if (_viewType == StudentViewType.byClass) {
                          showClassRegistrationDialog();
                        } else {
                          showStudentRegistrationDialog();
                        }
                      },
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
                              return const Color(0xFF78909C);
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
} 