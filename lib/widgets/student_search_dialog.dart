import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';

class StudentSearchDialog extends StatefulWidget {
  final Set<String> excludedStudentIds;
  final bool isSelfStudyMode;
  
  const StudentSearchDialog({
    Key? key,
    this.excludedStudentIds = const {},
    this.isSelfStudyMode = false,
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

  /// 자습 등록 가능 학생 리스트 반환 (weeklyClassCount - setId 개수 <= 0)
  List<StudentWithInfo> getSelfStudyEligibleStudents() {
    final eligible = DataManager.instance.students.where((s) {
      final setCount = DataManager.instance.getStudentLessonSetCount(s.student.id);
      final remain = (s.basicInfo.weeklyClassCount) - setCount;
      print('[DEBUG][DataManager] getSelfStudyEligibleStudents: ${s.student.name}, remain=$remain');
      return remain <= 0;
    }).toList();
    print('[DEBUG][DataManager] getSelfStudyEligibleStudents: ${eligible.map((s) => s.student.name).toList()}');
    return eligible;
  }

  void _refreshStudentList() {
    if (widget.isSelfStudyMode) {
      _students = DataManager.instance.getSelfStudyEligibleStudents();
      print('[DEBUG][StudentSearchDialog] 자습 등록 가능 학생: ' + _students.map((s) => s.student.name).toList().toString());
    } else {
      _students = DataManager.instance.getLessonEligibleStudents();
      print('[DEBUG][StudentSearchDialog] 수업 등록 가능 학생: ' + _students.map((s) => s.student.name).toList().toString());
    }
    _filteredStudents = _students;
    setState(() {});
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