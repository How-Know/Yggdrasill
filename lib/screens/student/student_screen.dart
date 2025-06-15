import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/student_view_type.dart';
import 'package:mneme_flutter/screens/student/components/student_header.dart';
import 'package:mneme_flutter/screens/student/views/all_students_view.dart';
import 'package:mneme_flutter/screens/student/views/class_view.dart';
import 'package:mneme_flutter/screens/student/views/date_view.dart';
import 'package:mneme_flutter/screens/student/views/school_view.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:mneme_flutter/widgets/student_details_dialog.dart';
import 'package:mneme_flutter/widgets/student_registration_dialog.dart';

class StudentScreen extends StatefulWidget {
  const StudentScreen({Key? key}) : super(key: key);

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  StudentViewType _viewType = StudentViewType.all;
  List<Student> _students = [];
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadStudents();
    setState(() {
      _students = List.from(DataManager.instance.students);
    });
  }

  List<Student> get _filteredStudents {
    if (_searchQuery.isEmpty) {
      return _students;
    }
    return _students.where((student) {
      final searchLower = _searchQuery.toLowerCase();
      return student.name.toLowerCase().contains(searchLower) ||
          student.school.toLowerCase().contains(searchLower);
    }).toList();
  }

  void _handleViewTypeChanged(StudentViewType viewType) {
    setState(() {
      _viewType = viewType;
    });
  }

  void _handleSearch(String query) {
    setState(() {
      _searchQuery = query;
    });
  }

  Future<void> _handleAddStudent() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        onSave: (student) async {
          await DataManager.instance.addStudent(student);
          setState(() {
            _students = List.from(DataManager.instance.students);
          });
        },
        classes: DataManager.instance.classes,
      ),
    );

    if (result == true) {
      await _loadData();
    }
  }

  Future<void> _handleShowDetails(Student student) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StudentDetailsDialog(student: student),
    );

    if (result == true) {
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        StudentHeader(
          viewType: _viewType,
          onViewTypeChanged: _handleViewTypeChanged,
          onSearch: _handleSearch,
          onAddStudent: _handleAddStudent,
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              switch (_viewType) {
                case StudentViewType.all:
                  return AllStudentsView(
                    students: _filteredStudents,
                    onShowDetails: _handleShowDetails,
                  );
                case StudentViewType.byClass:
                  return ClassView(
                    students: _filteredStudents,
                    onShowDetails: _handleShowDetails,
                  );
                case StudentViewType.bySchool:
                  return SchoolView(
                    students: _filteredStudents,
                    onShowDetails: _handleShowDetails,
                  );
                case StudentViewType.byDate:
                  return DateView(
                    students: _filteredStudents,
                    onShowDetails: _handleShowDetails,
                  );
              }
            },
          ),
        ),
      ],
    );
  }
} 