import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
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
  String? _selectedClassId;

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
      _students = _getRecommendedStudentsByActualClassCount();
      // weekly_class_count 값 확인용 로그 (0으로 표시되는지 추적)
      for (final s in _students) {
        final weekly = DataManager.instance.getStudentWeeklyClassCount(s.student.id);
        final actual = _getActualClassCount(s.student.id);
        print('[DEBUG][StudentSearchDialog] 추천: ${s.student.name}, weekly=$weekly, actual=$actual');
      }
    }
    _filteredStudents = _students;
    setState(() {});
  }

  /// 실제 수업 개수(수업별 고유 setId) + setId 없는 수업은 1로 카운트
  int _getActualClassCount(String studentId) {
    final dm = DataManager.instance;
    final allBlocks = dm.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
    final Map<String, Set<String?>> setsByClass = {};
    for (final b in allBlocks) {
      final cls = b.sessionTypeId ?? 'default_class';
      setsByClass.putIfAbsent(cls, () => <String?>{});
      setsByClass[cls]!.add(b.setId);
    }
    int total = 0;
    for (final entry in setsByClass.entries) {
      final setIds = entry.value;
      final nonNull = setIds.whereType<String>().toSet();
      final hasNull = setIds.any((v) => v == null || (v is String && v.isEmpty));
      final count = nonNull.length + (hasNull ? 1 : 0);
      total += count;
    }
    return total;
  }

  /// 추천 학생: weekly_class_count > 실제 수업 개수 인 학생들
  List<StudentWithInfo> _getRecommendedStudentsByActualClassCount() {
    final dm = DataManager.instance;
    final list = dm.students.where((s) {
      final actual = _getActualClassCount(s.student.id);
      final weekly = dm.getStudentWeeklyClassCount(s.student.id);
      return actual < weekly;
    }).toList();
    // remaining 내림차순 → 이름순
    list.sort((a, b) {
      final ra = dm.getStudentWeeklyClassCount(a.student.id) - _getActualClassCount(a.student.id);
      final rb = dm.getStudentWeeklyClassCount(b.student.id) - _getActualClassCount(b.student.id);
      if (rb != ra) return rb.compareTo(ra);
      return a.student.name.compareTo(b.student.name);
    });
    return list;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshStudentList();
  }

  void _filterStudents(String query) {
    setState(() {
      final searchQuery = query.trim().toLowerCase();
      if (searchQuery.isEmpty) {
        // 빈 검색어면 추천/자습 대상(_students) 그대로
        _filteredStudents = _students;
        return;
      }
      // 검색 시에는 전체 학생 대상으로 필터 (weekly_class_count 충족 여부 무시)
      final all = DataManager.instance.students;
      _filteredStudents = all.where((studentWithInfo) {
        final name = studentWithInfo.student.name.toLowerCase();
        final school = (studentWithInfo.student.school ?? '').toLowerCase();
        return name.contains(searchQuery) || school.contains(searchQuery);
      }).toList();
    });
  }

  /// 학생이 등록된 수업이 있는지 확인 (setId 기준, 수업명 없음 포함)
  bool _hasRegisteredClasses(String studentId) {
    final setCount = _getActualClassCount(studentId);
    return setCount > 0;
  }

  /// 수업 정보를 색상이 적용된 위젯으로 반환
  Widget _buildClassInfoWidget(String studentId, {required int setCount, required int weeklyCount}) {
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
    
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        '등록 $setCount개 / 총 수업 $weeklyCount개',
        style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildGroupIndicator(StudentWithInfo s) {
    final groupId = s.basicInfo.groupId ?? s.student.groupInfo?.id;
    final group = DataManager.instance.groups.firstWhere(
      (g) => g.id == groupId,
      orElse: () => GroupInfo(
        id: '',
        name: '',
        description: '',
        capacity: null,
        duration: 0,
        color: const Color(0xFF1B6B63),
      ),
    );
    final color = groupId == null || groupId.isEmpty ? Colors.white24 : group.color;
    return Container(
      width: 8,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildClassDropdown() {
    final classes = DataManager.instance.classes;
    final items = [
      const DropdownMenuItem<String?>(
        value: null,
        child: Text('수업 선택 없음'),
      ),
      ...classes.map((c) => DropdownMenuItem<String?>(
            value: c.id,
            child: Text(c.name, overflow: TextOverflow.ellipsis),
          )),
    ];
    return DropdownButtonFormField<String?>(
      value: _selectedClassId,
      items: items,
      onChanged: (v) {
        setState(() => _selectedClassId = v);
        print('[DEBUG][StudentSearchDialog] dropdown changed -> $_selectedClassId');
      },
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: const Color(0xFF111418),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF223131)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1B6B63), width: 1.4),
        ),
      ),
      dropdownColor: const Color(0xFF111418),
      iconEnabledColor: Colors.white70,
      style: const TextStyle(color: Color(0xFFEAF2F2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B1112),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '학생 검색',
                style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      onChanged: _filterStudents,
                      decoration: _searchDecoration(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 180,
                    child: _buildClassDropdown(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111418),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  child: _filteredStudents.isEmpty
                      ? const Center(
                          child: Text('검색 결과가 없습니다.', style: TextStyle(color: Colors.white54, fontSize: 15)),
                        )
                      : ListView.separated(
                          itemCount: _filteredStudents.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.white.withOpacity(0.06)),
                          itemBuilder: (context, index) {
                            final studentWithInfo = _filteredStudents[index];
                            final student = studentWithInfo.student;
                            final int setCount = _getActualClassCount(student.id);
                            final bool hasClasses = setCount > 0;
                            final int weeklyCount = DataManager.instance.getStudentWeeklyClassCount(student.id);
                            return InkWell(
                              onTap: () {
                                print('[DEBUG][StudentSearchDialog] confirm -> student=${student.id}, classId=$_selectedClassId');
                                Navigator.of(context).pop({
                                  'student': student,
                                  'classId': _selectedClassId,
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildGroupIndicator(studentWithInfo),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            student.name,
                                            style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w600),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${student.school ?? ''} ${student.grade != null ? '${student.grade}학년' : ''}',
                                            style: TextStyle(color: Colors.white70, fontSize: 13),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (hasClasses) ...[
                                      const SizedBox(width: 12),
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 180),
                                        child: _buildClassInfoWidget(student.id, setCount: setCount, weeklyCount: weeklyCount),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소', style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _searchDecoration() {
    return InputDecoration(
      hintText: '학생 이름 또는 학교 검색',
      hintStyle: const TextStyle(color: Colors.white38),
      prefixIcon: const Icon(Icons.search, color: Colors.white70),
      filled: true,
      fillColor: const Color(0xFF111418),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Color(0xFF223131)),
        borderRadius: BorderRadius.circular(10),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Color(0xFF1B6B63), width: 1.4),
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }

  @override
  void dispose() {
    DataManager.instance.studentTimeBlocksNotifier.removeListener(_refreshStudentList); // 리스너 해제
    super.dispose();
  }
} 

