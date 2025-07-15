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
  List<StudentWithInfo> _students = [];
  List<StudentWithInfo> _filteredStudents = [];

  @override
  void initState() {
    super.initState();
    _refreshStudentList();
    DataManager.instance.studentTimeBlocksNotifier.addListener(_refreshStudentList); // 시간표 변경 시 자동 새로고침
  }

  void _refreshStudentList() {
    final allStudents = DataManager.instance.students
        .where((studentWithInfo) => !widget.excludedStudentIds.contains(studentWithInfo.student.id))
        .toList();
    if (widget.onlyShowIncompleteStudents) {
      // 학생별로 등록된 수업시간 개수와 weeklyClassCount 비교
      final timeBlocks = DataManager.instance.studentTimeBlocks;
      _students = allStudents.where((studentWithInfo) {
        final count = timeBlocks.where((b) => b.studentId == studentWithInfo.student.id).length;
        final required = studentWithInfo.basicInfo.weeklyClassCount;
        final include = count < required;
        print('[학생리스트필터] name=${studentWithInfo.student.name}, id=${studentWithInfo.student.id}, weeklyClassCount=$required, 등록된블록개수=$count, 리스트포함=$include');
        return include;
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
      _filteredStudents = _students.where((studentWithInfo) {
        final name = studentWithInfo.student.name.toLowerCase();
        final school = studentWithInfo.student.school?.toLowerCase() ?? '';
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
                  final studentWithInfo = _filteredStudents[index];
                  final student = studentWithInfo.student;
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
    DataManager.instance.studentTimeBlocksNotifier.removeListener(_refreshStudentList); // 리스너 해제
    super.dispose();
  }
} 