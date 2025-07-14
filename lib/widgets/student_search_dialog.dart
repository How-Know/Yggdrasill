import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';

class StudentSearchDialog extends StatefulWidget {
  final Set<String> excludedStudentIds;
  final bool onlyShowIncompleteStudents;
  
  const StudentSearchDialog({
    Key? key,
    this.excludedStudentIds = const {},
    this.onlyShowIncompleteStudents = false,
  }) : super(key: key);

  @override
  State<StudentSearchDialog> createState() => _StudentSearchDialogState();
}

class _StudentSearchDialogState extends State<StudentSearchDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<Student> _students = [];
  List<Student> _filteredStudents = [];

  @override
  void initState() {
    super.initState();
    _refreshStudentList();
  }

  void _refreshStudentList() {
    final allStudents = DataManager.instance.students
        .where((student) => !widget.excludedStudentIds.contains(student.student.id))
        .map((s) => s.student)
        .toList();
    if (widget.onlyShowIncompleteStudents) {
      // 학생별로 등록된 수업시간 개수와 weeklyClassCount 비교
      final timeBlocks = DataManager.instance.studentTimeBlocks;
      _students = allStudents.where((student) {
        final count = timeBlocks.where((b) => b.studentId == student.id).length;
        final required = student.weeklyClassCount ?? 1;
        return count < required;
      }).toList();
    } else {
      _students = allStudents;
    }
    _filteredStudents = _students;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshStudentList();
  }

  void _filterStudents(String query) {
    _refreshStudentList();
    setState(() {
      _filteredStudents = _students.where((student) {
        final name = student.name.toLowerCase();
        final school = student.school?.toLowerCase() ?? '';
        final searchQuery = query.toLowerCase();
        return name.contains(searchQuery) || school.contains(searchQuery);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text(
        '학생 검색',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: _filterStudents,
              decoration: InputDecoration(
                labelText: '학생 이름 또는 학교 검색',
                labelStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _filteredStudents.length,
                itemBuilder: (context, index) {
                  final student = _filteredStudents[index];
                  return ListTile(
                    title: Text(
                      student.name,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      '${student.school ?? ''} ${student.grade != null ? '${student.grade}학년' : ''}',
                      style: TextStyle(color: Colors.white.withOpacity(0.7)),
                    ),
                    onTap: () {
                      Navigator.of(context).pop(student);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '취소',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
} 