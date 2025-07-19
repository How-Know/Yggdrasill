import 'package:flutter/material.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/student_card.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../main.dart'; // rootScaffoldMessengerKey import
import '../../../models/student_time_block.dart';

class TimetableContentView extends StatefulWidget {
  final Widget timetableChild;
  final VoidCallback onRegisterPressed;
  final String splitButtonSelected;
  final bool isDropdownOpen;
  final ValueChanged<bool> onDropdownOpenChanged;
  final ValueChanged<String> onDropdownSelected;
  final List<StudentWithInfo>? selectedCellStudents;
  final int? selectedCellDayIndex;
  final DateTime? selectedCellStartTime;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)? onCellStudentsChanged;
  final VoidCallback? clearSearch; // 추가: 외부에서 검색 리셋 요청
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;

  const TimetableContentView({
    Key? key,
    required this.timetableChild,
    required this.onRegisterPressed,
    required this.splitButtonSelected,
    required this.isDropdownOpen,
    required this.onDropdownOpenChanged,
    required this.onDropdownSelected,
    this.selectedCellStudents,
    this.selectedCellDayIndex,
    this.selectedCellStartTime,
    this.onCellStudentsChanged,
    this.clearSearch, // 추가
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
  }) : super(key: key);

  @override
  State<TimetableContentView> createState() => TimetableContentViewState();
}

class TimetableContentViewState extends State<TimetableContentView> {
  final GlobalKey _dropdownButtonKey = GlobalKey();
  OverlayEntry? _dropdownOverlay;
  bool _showDeleteZone = false;
  String _searchQuery = '';
  List<StudentWithInfo> _searchResults = [];
  final TextEditingController _searchController = TextEditingController();

  void _showDropdownMenu() {
    final RenderBox buttonRenderBox = _dropdownButtonKey.currentContext!.findRenderObject() as RenderBox;
    final Offset buttonPosition = buttonRenderBox.localToGlobal(Offset.zero);
    final Size buttonSize = buttonRenderBox.size;
    _dropdownOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: buttonPosition.dx,
        top: buttonPosition.dy + buttonSize.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 140,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Color(0xFF2A2A2A), width: 1), // 윤곽선이 티 안 나게
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ...['학생', '그룹', '보강', '자습'].map((label) => _DropdownMenuHoverItem(
                  label: label,
                  selected: widget.splitButtonSelected == label,
                  onTap: () {
                    widget.onDropdownSelected(label);
                    _removeDropdownMenu();
                  },
                )),
              ],
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_dropdownOverlay!);
  }

  void _removeDropdownMenu() {
    _dropdownOverlay?.remove();
    _dropdownOverlay = null;
    widget.onDropdownOpenChanged(false);
  }

  @override
  void dispose() {
    _removeDropdownMenu();
    super.dispose();
  }

  // 외부에서 검색 상태를 리셋할 수 있도록 public 메서드 제공
  void clearSearch() {
    if (_searchQuery.isNotEmpty || _searchResults.isNotEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = [];
        _searchController.clear();
      });
    }
  }

  // timetable_content_view.dart에 아래 메서드 추가(클래스 내부)
  void updateCellStudentsAfterMove(int dayIdx, DateTime startTime) {
    final updatedBlocks = DataManager.instance.studentTimeBlocks.where((b) =>
      b.dayIndex == dayIdx &&
      b.startTime.hour == startTime.hour &&
      b.startTime.minute == startTime.minute
    ).toList();
    final updatedStudents = DataManager.instance.students;
    final updatedCellStudents = updatedBlocks.map((b) =>
      updatedStudents.firstWhere(
        (s) => s.student.id == b.studentId,
        orElse: () => StudentWithInfo(
          student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
          basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
        ),
      )
    ).toList();
    if (widget.onCellStudentsChanged != null) {
      widget.onCellStudentsChanged!(dayIdx, startTime, updatedCellStudents);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.8 + 24;
    return Row(
      children: [
        const SizedBox(width: 24),
        Expanded(
          flex: 3,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 0), // vertical 32 -> 16으로 조정
            decoration: BoxDecoration(
              color: const Color(0xFF18181A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: widget.timetableChild,
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                flex: 3, // 3:5 비율로 수정
                child: Container(
                  margin: const EdgeInsets.only(bottom: 16, top: 8, left: 4, right: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.13),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          SizedBox(
                            width: 113,
                            height: 44,
                            child: Material(
                              color: const Color(0xFF1976D2),
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(32),
                                bottomLeft: Radius.circular(32),
                                topRight: Radius.circular(6),
                                bottomRight: Radius.circular(6),
                              ),
                              child: InkWell(
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(32),
                                  bottomLeft: Radius.circular(32),
                                  topRight: Radius.circular(6),
                                  bottomRight: Radius.circular(6),
                                ),
                                onTap: widget.onRegisterPressed,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.max,
                                  children: const [
                                    Icon(Icons.edit, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Text('등록', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // 구분선
                          Container(
                            height: 44,
                            width: 3.0,
                            color: Colors.transparent,
                            child: Center(
                              child: Container(
                                width: 2,
                                height: 28,
                                color: Colors.white.withOpacity(0.1),
                              ),
                            ),
                          ),
                          // 드롭다운 버튼
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.5),
                            child: GestureDetector(
                              key: _dropdownButtonKey,
                              onTap: () {
                                if (_dropdownOverlay == null) {
                                  widget.onDropdownOpenChanged(true);
                                  _showDropdownMenu();
                                } else {
                                  _removeDropdownMenu();
                                }
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 350),
                                width: 44,
                                height: 44,
                                decoration: ShapeDecoration(
                                  color: const Color(0xFF1976D2),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: widget.isDropdownOpen
                                      ? BorderRadius.circular(50)
                                      : const BorderRadius.only(
                                          topLeft: Radius.circular(6),
                                          bottomLeft: Radius.circular(6),
                                          topRight: Radius.circular(32),
                                          bottomRight: Radius.circular(32),
                                        ),
                                  ),
                                ),
                                child: Center(
                                  child: AnimatedRotation(
                                    turns: widget.isDropdownOpen ? 0.5 : 0.0,
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeInOut,
                                    child: const Icon(
                                      Icons.keyboard_arrow_down,
                                      color: Colors.white,
                                      size: 28,
                                      key: ValueKey('arrow'),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 학생 메뉴와 동일한 SearchBar (오른쪽 정렬, 고정 너비, 스타일 일치)
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(width: 16),
                                  SizedBox(
                                    width: 220,
                                    height: 48,
                                    child: SearchBar(
                                      controller: _searchController,
                                      onChanged: _onSearchChanged,
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
                                        BorderSide(color: Colors.white.withOpacity(0.2), width: 1, style: BorderStyle.solid),
                                      ),
                                      constraints: const BoxConstraints(
                                        minHeight: 50,
                                        maxHeight: 50,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 학생카드 리스트 위에 요일+시간 출력
                      if (_searchQuery.isNotEmpty && _searchResults.isNotEmpty)
                        Expanded(
                          child: SingleChildScrollView(
                            child: _buildGroupedStudentCardsByDayTime(_searchResults),
                          ),
                        )
                      else if (widget.selectedCellStudents != null && widget.selectedCellStudents!.isNotEmpty)
                        Expanded(
                          child: SingleChildScrollView(
                            child: _buildStudentCardList(
                              widget.selectedCellStudents!,
                              dayTimeLabel: widget.selectedCellDayIndex != null && widget.selectedCellStartTime != null
                                ? _getDayTimeString(widget.selectedCellDayIndex, widget.selectedCellStartTime)
                                : null,
                            ),
                          ),
                        )
                      else
                        const Expanded(
                          child: Center(
                            child: Text('학생을 검색하거나 셀을 선택하세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
                          ),
                        ),
                  // 삭제 드롭존
                  if (_showDeleteZone)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: DragTarget<Map<String, dynamic>>(
                        onWillAccept: (data) => true,
                        onAccept: (data) async {
                          final student = data['student'] as StudentWithInfo;
                          final oldDayIndex = data['oldDayIndex'] as int?;
                          final oldStartTime = data['oldStartTime'] as DateTime?;
                          print('[삭제드롭존] onAccept 호출: studentId= [33m${student.student.id} [0m, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime');

                          // setId 진단 로그 추가
                          print('[삭제드롭존][진단] 전체 studentTimeBlocks setId 목록: ' + DataManager.instance.studentTimeBlocks.map((b) => b.setId).toList().toString());

                          // 1. 해당 학생+요일+시간 블록 1개 찾기 (setId 추출용)
                          final targetBlock = DataManager.instance.studentTimeBlocks.firstWhere(
                            (b) =>
                              b.studentId == student.student.id &&
                              b.dayIndex == oldDayIndex &&
                              b.startTime.hour == oldStartTime?.hour &&
                              b.startTime.minute == oldStartTime?.minute,
                            orElse: () => StudentTimeBlock(
                              id: '',
                              studentId: '',
                              dayIndex: -1,
                              startTime: DateTime(0),
                              duration: Duration.zero,
                              createdAt: DateTime(0),
                              setId: null,
                              number: null,
                            ),
                          );

                          if (targetBlock != null && targetBlock.setId != null) {
                            // setId+studentId로 모든 블록 삭제 (일괄 삭제)
                            final allBlocks = DataManager.instance.studentTimeBlocks;
                            final toDelete = allBlocks.where((b) => b.setId == targetBlock.setId && b.studentId == student.student.id).toList();
                            for (final b in toDelete) {
                              print('[삭제드롭존] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}');
                              await DataManager.instance.removeStudentTimeBlock(b.id);
                            }
                            // 삭제 후 데이터 새로고침 (일괄)
                            await DataManager.instance.loadStudents();
                            await DataManager.instance.loadStudentTimeBlocks();
                          } else if (oldDayIndex != null && oldStartTime != null) {
                            // setId가 없는 경우 단일 블록 삭제
                            final blocks = DataManager.instance.studentTimeBlocks.where((b) =>
                              b.studentId == student.student.id &&
                              b.dayIndex == oldDayIndex &&
                              b.startTime.hour == oldStartTime.hour &&
                              b.startTime.minute == oldStartTime.minute
                            ).toList();
                            for (final block in blocks) {
                              print('[삭제드롭존] 삭제 시도: block.id=${block.id}, block.dayIndex=${block.dayIndex}, block.startTime=${block.startTime}');
                              await DataManager.instance.removeStudentTimeBlock(block.id);
                            }
                            // 삭제 후 데이터 새로고침 (일괄)
                            await DataManager.instance.loadStudents();
                            await DataManager.instance.loadStudentTimeBlocks();
                          }
                          // 삭제 후 데이터 즉시 새로고침
                          setState(() {
                            _showDeleteZone = false;
                            // (필요하다면 다른 상태도 여기서 갱신)
                          });
                          print('[삭제드롭존] 삭제 후 studentTimeBlocks 개수: ${DataManager.instance.studentTimeBlocks.length}');
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                rootScaffoldMessengerKey.currentState?.showSnackBar(
                                  SnackBar(
                                    content: Text('${student.student.name} 학생의 수업시간이 삭제되었습니다.'),
                                    backgroundColor: const Color(0xFF1976D2),
                                    behavior: SnackBarBehavior.floating,
                                    margin: const EdgeInsets.only(bottom: 80, left: 20, right: 20),
                                  ),
                                );
                              }
                            });
                          });
                          // 삭제 후 등록버튼 컨테이너 내 학생카드 리스트도 즉시 반영 (데이터 새로고침 후에 실행)
                          if (widget.selectedCellDayIndex != null && widget.selectedCellStartTime != null) {
                            final updatedBlocks = DataManager.instance.studentTimeBlocks.where((b) =>
                              b.dayIndex == widget.selectedCellDayIndex &&
                              b.startTime.hour == widget.selectedCellStartTime!.hour &&
                              b.startTime.minute == widget.selectedCellStartTime!.minute
                            ).toList();
                            final updatedStudents = DataManager.instance.students;
                            final updatedCellStudents = updatedBlocks.map((b) =>
                              updatedStudents.firstWhere(
                                (s) => s.student.id == b.studentId,
                                orElse: () => StudentWithInfo(
                                  student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                                  basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
                                ),
                              )
                            ).toList();
                            if (widget.onCellStudentsChanged != null) {
                              widget.onCellStudentsChanged!(widget.selectedCellDayIndex!, widget.selectedCellStartTime!, updatedCellStudents);
                            }
                          }
                        },
                        builder: (context, candidateData, rejectedData) {
                          final isHover = candidateData.isNotEmpty;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: double.infinity,
                            height: 72,
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              border: Border.all(
                                color: isHover ? Colors.red : Colors.grey[700]!,
                                width: isHover ? 3 : 2,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.delete_outline,
                                color: isHover ? Colors.red : Colors.white70,
                                size: 36,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 5, // 3:5 비율로 수정
                child: Container(
                  margin: const EdgeInsets.only(top: 16, left: 4, right: 4, bottom: 8),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.13),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '컨테이너 (1)',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
      ],
    );
  }

  // --- 학생카드 Draggable 래퍼 공통 함수 ---
  Widget _buildDraggableStudentCard(StudentWithInfo info, {int? dayIndex, DateTime? startTime}) {
    return Draggable<Map<String, dynamic>>(
      data: {
        'student': info,
        'oldDayIndex': dayIndex,
        'oldStartTime': startTime,
      },
      onDragStarted: () => setState(() => _showDeleteZone = true),
      onDragEnd: (_) => setState(() => _showDeleteZone = false),
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: StudentCard(
            studentWithInfo: info,
            onShowDetails: (info) {},
            showCheckbox: widget.isSelectMode,
            checked: widget.selectedStudentIds.contains(info.student.id),
            onCheckboxChanged: (checked) {
              if (widget.onStudentSelectChanged != null && checked != null) {
                widget.onStudentSelectChanged!(info.student.id, checked);
              }
            },
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: StudentCard(
          studentWithInfo: info,
          onShowDetails: (info) {},
          showCheckbox: widget.isSelectMode,
          checked: widget.selectedStudentIds.contains(info.student.id),
          onCheckboxChanged: (checked) {
            if (widget.onStudentSelectChanged != null && checked != null) {
              widget.onStudentSelectChanged!(info.student.id, checked);
            }
          },
        ),
      ),
      child: StudentCard(
        studentWithInfo: info,
        onShowDetails: (info) {},
        showCheckbox: widget.isSelectMode,
        checked: widget.selectedStudentIds.contains(info.student.id),
        onCheckboxChanged: (checked) {
          if (widget.onStudentSelectChanged != null && checked != null) {
            widget.onStudentSelectChanged!(info.student.id, checked);
          }
        },
      ),
    );
  }

  // --- 학생카드 리스트(셀 선택/검색 결과) 공통 출력 함수 ---
  Widget _buildStudentCardList(List<StudentWithInfo> students, {String? dayTimeLabel}) {
    if (students.isEmpty) {
      return const Center(
        child: Text('학생을 검색하거나 셀을 선택하세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dayTimeLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 8.0),
            child: Text(
              dayTimeLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 20),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 16.0), // 상단 여백을 16으로 늘림
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: students.map((info) =>
              _buildDraggableStudentCard(info, dayIndex: widget.selectedCellDayIndex, startTime: widget.selectedCellStartTime)
            ).toList(),
          ),
        ),
      ],
    );
  }

  // --- 검색 결과를 요일/시간별로 그룹핑해서 보여주는 함수 ---
  Widget _buildGroupedStudentCardsByDayTime(List<StudentWithInfo> students) {
    // 학생이 속한 모든 시간블록을 (요일, 시간)별로 그룹핑
    final blocks = DataManager.instance.studentTimeBlocks;
    // Map<(dayIdx, startTime), List<StudentWithInfo>>
    final Map<String, List<StudentWithInfo>> grouped = {};
    for (final student in students) {
      final studentBlocks = blocks.where((b) => b.studentId == student.student.id).toList();
      for (final block in studentBlocks) {
        final key = '${block.dayIndex}-${block.startTime.hour}:${block.startTime.minute.toString().padLeft(2, '0')}';
        grouped.putIfAbsent(key, () => []);
        grouped[key]!.add(student);
      }
    }
    // key를 요일/시간 순으로 정렬
    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        final aDay = int.parse(a.split('-')[0]);
        final aTime = a.split('-')[1];
        final bDay = int.parse(b.split('-')[0]);
        final bTime = b.split('-')[1];
        if (aDay != bDay) return aDay.compareTo(bDay);
        return aTime.compareTo(bTime);
      });
    if (grouped.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 32.0),
        child: Center(
          child: Text('검색된 학생이 시간표에 등록되어 있지 않습니다.', style: TextStyle(color: Colors.white38, fontSize: 16)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24), // 검색 결과 상단 여백
        ...sortedKeys.map((key) {
          final dayIdx = int.parse(key.split('-')[0]);
          final timeStr = key.split('-')[1];
          final hour = int.parse(timeStr.split(':')[0]);
          final min = int.parse(timeStr.split(':')[1]);
          final dayTimeLabel = _getDayTimeString(dayIdx, DateTime(0, 1, 1, hour, min));
          final students = grouped[key]!;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 90,
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Text(
                    dayTimeLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 0,
                    runSpacing: 4,
                    children: students.map((info) =>
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: _buildDraggableStudentCard(info, dayIndex: dayIdx, startTime: DateTime(0, 1, 1, hour, min)),
                      )
                    ).toList(),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      _searchResults = DataManager.instance.students.where((student) {
        final nameMatch = student.student.name.toLowerCase().contains(_searchQuery.toLowerCase());
        final schoolMatch = student.student.school.toLowerCase().contains(_searchQuery.toLowerCase());
        final gradeMatch = student.student.grade.toString().contains(_searchQuery);
        return nameMatch || schoolMatch || gradeMatch;
      }).toList();
    });
  }
}

// 드롭다운 메뉴 항목 위젯
class _DropdownMenuHoverItem extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DropdownMenuHoverItem({required this.label, required this.selected, required this.onTap});

  @override
  State<_DropdownMenuHoverItem> createState() => _DropdownMenuHoverItemState();
}

class _DropdownMenuHoverItemState extends State<_DropdownMenuHoverItem> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final highlight = _hovered || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 140,
          height: 40,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          decoration: BoxDecoration(
            color: highlight ? const Color(0xFF383838).withOpacity(0.7) : Colors.transparent, // 학생등록 다이얼로그와 유사한 하이라이트
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

  String _getDayTimeString(int? dayIdx, DateTime? startTime) {
    if (dayIdx == null || startTime == null) return '';
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    final dayStr = (dayIdx >= 0 && dayIdx < days.length) ? days[dayIdx] : '';
    final hour = startTime.hour.toString().padLeft(2, '0');
    final min = startTime.minute.toString().padLeft(2, '0');
    return '$dayStr요일 $hour:$min';
  } 