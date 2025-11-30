import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

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
  final TextEditingController _searchController = ImeAwareTextEditingController();
  List<StudentWithInfo> _students = [];
  List<StudentWithInfo> _filteredStudents = [];

  @override
  void initState() {
    super.initState();
    _refreshStudentList();
    DataManager.instance.studentTimeBlocksNotifier.addListener(_refreshStudentList); // 시간표 변경 시 자동 새로고침
  }

  /// 자습 등록 가능 학생 리스트 반환 (수업이 등록된 학생들)
  List<StudentWithInfo> getSelfStudyEligibleStudents() {
    final eligible = DataManager.instance.students.where((s) {
      final setCount = DataManager.instance.getStudentLessonSetCount(s.student.id);
      print('[DEBUG][StudentSearchDialog] getSelfStudyEligibleStudents: ${s.student.name}, setCount=$setCount');
      return setCount > 0; // 수업이 하나 이상 등록된 학생만
    }).toList();
    print('[DEBUG][StudentSearchDialog] getSelfStudyEligibleStudents: ${eligible.map((s) => s.student.name).toList()}');
    return eligible;
  }

  void _refreshStudentList() {
    if (widget.isSelfStudyMode) {
      _students = DataManager.instance.getSelfStudyEligibleStudents();
      print('[DEBUG][StudentSearchDialog] 자습 등록 가능 학생: ' + _students.map((s) => s.student.name).toList().toString());
    } else {
      // 추천 학생: weekly_class_count > set_id 개수(미만)인 학생들
      _students = DataManager.instance.getRecommendedStudentsForWeeklyClassCount();
      print('[DEBUG][StudentSearchDialog] 추천 학생(weekly_class_count 기준): ' + _students.map((s) => s.student.name).toList().toString());
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
    setState(() {
      // 검색은 필터 없이 전체 학생 대상
      final allStudents = DataManager.instance.students;
      if (query.trim().isEmpty) {
        _filteredStudents = allStudents;
      } else {
        _filteredStudents = allStudents.where((studentWithInfo) {
          final name = studentWithInfo.student.name.toLowerCase();
          final school = studentWithInfo.student.school.toLowerCase();
          final searchQuery = query.toLowerCase();
          return name.contains(searchQuery) || school.contains(searchQuery);
        }).toList();
      }
    });
  }

  /// 학생이 등록된 수업이 있는지 확인
  bool _hasRegisteredClasses(String studentId) {
    final allTimeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList();
    
    final timeBlocksWithSessionType = allTimeBlocks
        .where((block) => block.sessionTypeId != null)
        .toList();
    
    print('[DEBUG] _hasRegisteredClasses: 학생 $studentId의 전체 블록: ${allTimeBlocks.length}개, sessionTypeId 있는 블록: ${timeBlocksWithSessionType.length}개');
    
    return allTimeBlocks.isNotEmpty; // sessionTypeId가 없어도 시간블록이 있으면 수업으로 간주
  }

  /// 수업 정보를 색상이 적용된 위젯으로 반환
  Widget _buildClassInfoWidget(String studentId) {
    final allTimeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList();
    print('[DEBUG] 학생 $studentId의 전체 시간블록: ${allTimeBlocks.length}개');
    
    if (allTimeBlocks.isEmpty) {
      return const SizedBox.shrink();
    }
    
    // setId 기준으로 그룹핑하여 수업별 세트 개수 계산
    final Map<String, Set<String?>> classSetIds = {};
    
    for (final block in allTimeBlocks) {
      final sessionTypeId = block.sessionTypeId ?? 'default_class';
      if (classSetIds[sessionTypeId] == null) {
        classSetIds[sessionTypeId] = <String?>{};
      }
      classSetIds[sessionTypeId]!.add(block.setId);
      print('[DEBUG] 블록 sessionTypeId: ${block.sessionTypeId} -> $sessionTypeId, setId: ${block.setId}');
    }
    
    // 각 수업별 고유한 setId 개수 계산
    final Map<String, int> classCounts = {};
    for (final entry in classSetIds.entries) {
      classCounts[entry.key] = entry.value.length;
      print('[DEBUG] 수업 ${entry.key}: ${entry.value.length}개 세트 (setIds: ${entry.value})');
    }
    
    // 수업 정보를 위젯으로 변환
    final classWidgets = classCounts.entries.map((entry) {
      final classId = entry.key;
      final count = entry.value;
      
      // ClassInfo에서 수업명과 색상 찾기
      String className;
      Color classColor;
      
      if (classId == 'default_class') {
        // sessionTypeId가 없는 경우
        className = '수업';
        classColor = Colors.white.withOpacity(0.7);
        print('[DEBUG] 기본 수업 처리: $className');
      } else {
        // sessionTypeId가 있는 경우
        print('[DEBUG] 찾는 classId: $classId, 전체 수업 수: ${DataManager.instance.classes.length}');
        final classInfo = DataManager.instance.classes
            .where((c) => c.id == classId)
            .firstOrNull;
        
        className = classInfo?.name ?? '알 수 없는 수업';
        classColor = classInfo?.color ?? Colors.white.withOpacity(0.7);
        print('[DEBUG] 찾은 수업: $className (색상: $classColor)');
      }
      
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: className,
              style: TextStyle(
                color: classColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: ' ($count개)',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
    }).toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: classWidgets,
    );
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] StudentSearchDialog build - 수정된 버전');
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
                  
                  // 학생의 수업 정보 확인
                  final hasClasses = _hasRegisteredClasses(student.id);
                  print('[DEBUG] 학생 ${student.name} 수업 있나요: $hasClasses');
                  
                  return ListTile(
                    title: Text(
                      student.name,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      '${student.school ?? ''} ${student.grade != null ? '${student.grade}학년' : ''}',
                      style: TextStyle(color: Colors.white.withOpacity(0.7)),
                    ),
                    trailing: hasClasses 
                        ? Container(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: _buildClassInfoWidget(student.id),
                          )
                        : null,
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

