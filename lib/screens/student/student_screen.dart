import 'package:flutter/material.dart';
import '../../models/student.dart';
import '../../widgets/student_registration_dialog.dart';
import 'components/student_header.dart';
import 'views/all_students_view.dart';
import 'views/school_view.dart';

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key});

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  StudentViewType _viewType = StudentViewType.all;
  final List<Student> _students = [];
  final List<ClassInfo> _classes = [];
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
          StudentHeader(
            viewType: _viewType,
            onViewTypeChanged: (viewType) {
              setState(() {
                _viewType = viewType;
              });
            },
            onAddStudent: () => _showStudentRegistrationDialog(null),
            onSearch: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
            searchController: _searchController,
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
        return SchoolView(
          students: filteredStudents,
          classes: _classes,
          onEdit: _showStudentRegistrationDialog,
          onDelete: _showDeleteConfirmationDialog,
          onShowDetails: _showStudentDetails,
        );
      case StudentViewType.byDate:
        return _buildDateView();
      default:
        return AllStudentsView(
          students: filteredStudents,
          classes: _classes,
          onEdit: _showStudentRegistrationDialog,
          onDelete: _showDeleteConfirmationDialog,
          onShowDetails: _showStudentDetails,
        );
    }
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

  Widget _buildDateView() {
    // TODO: 수강 일자별 보기 구현
    return const Center(
      child: Text(
        '수강 일자별 보기 준비 중...',
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