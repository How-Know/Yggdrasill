import 'package:flutter/material.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/student_card.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../main.dart'; // rootScaffoldMessengerKey import
import '../../../models/student_time_block.dart';
import '../../../models/self_study_time_block.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../models/class_info.dart';

class TimetableContentView extends StatefulWidget {
  final Widget timetableChild;
  final VoidCallback onRegisterPressed;
  final String splitButtonSelected;
  final bool isDropdownOpen;
  final ValueChanged<bool> onDropdownOpenChanged;
  final ValueChanged<String> onDropdownSelected;
  final int? selectedCellDayIndex;
  final DateTime? selectedCellStartTime;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)? onCellStudentsChanged;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)? onCellSelfStudyStudentsChanged;
  final VoidCallback? clearSearch; // 추가: 외부에서 검색 리셋 요청
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;
  final VoidCallback? onExitSelectMode; // 추가: 다중모드 종료 콜백
  final String? registrationModeType;

  const TimetableContentView({
    Key? key,
    required this.timetableChild,
    required this.onRegisterPressed,
    required this.splitButtonSelected,
    required this.isDropdownOpen,
    required this.onDropdownOpenChanged,
    required this.onDropdownSelected,
    this.selectedCellDayIndex,
    this.selectedCellStartTime,
    this.onCellStudentsChanged,
    this.onCellSelfStudyStudentsChanged,
    this.clearSearch, // 추가
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
    this.onExitSelectMode,
    this.registrationModeType,
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
  bool isClassRegisterMode = false;

  @override
  void initState() {
    super.initState();
    DataManager.instance.loadClasses();
  }

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
                ...['학생', '보강', '자습'].map((label) => _DropdownMenuHoverItem(
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

  // 자습 블록 수정 (셀 위에 드롭)
  void _onSelfStudyBlockMoved(int dayIdx, DateTime startTime, List<StudentWithInfo> students) async {
    print('[DEBUG][_onSelfStudyBlockMoved] 호출: dayIdx=$dayIdx, startTime=$startTime, students=${students.map((s) => s.student.name).toList()}');
    
    // 이동할 자습 블록들 찾기 (현재 선택된 셀의 자습 블록들)
    final currentSelfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) {
      if (b.dayIndex != widget.selectedCellDayIndex || widget.selectedCellStartTime == null) return false;
      final blockStartMinutes = b.startTime.hour * 60 + b.startTime.minute;
      final blockEndMinutes = blockStartMinutes + b.duration.inMinutes;
      final checkMinutes = widget.selectedCellStartTime!.hour * 60 + widget.selectedCellStartTime!.minute;
      return checkMinutes >= blockStartMinutes && checkMinutes < blockEndMinutes;
    }).toList();
    
    if (currentSelfStudyBlocks.isEmpty) {
      print('[DEBUG][_onSelfStudyBlockMoved] 이동할 자습 블록이 없음');
      return;
    }
    
    // 중복 체크
    final blockMinutes = 30; // 자습 블록 길이
    bool hasConflict = false;
    for (final student in students) {
      for (final block in currentSelfStudyBlocks) {
        if (_isSelfStudyTimeOverlap(student.student.id, dayIdx, startTime, blockMinutes)) {
          hasConflict = true;
          break;
        }
      }
      if (hasConflict) break;
    }
    
    if (hasConflict) {
      showAppSnackBar(context, '이미 등록된 시간과 겹칩니다. 자습시간을 이동할 수 없습니다.', useRoot: true);
      return;
    }
    
    // 자습 블록 이동
    for (final block in currentSelfStudyBlocks) {
      final newBlock = block.copyWith(
        dayIndex: dayIdx,
        startTime: startTime,
      );
      await DataManager.instance.updateSelfStudyTimeBlock(block.id, newBlock);
    }
    
    // UI 업데이트
    final updatedSelfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) {
      if (b.dayIndex != dayIdx) return false;
      final blockStartMinutes = b.startTime.hour * 60 + b.startTime.minute;
      final blockEndMinutes = blockStartMinutes + b.duration.inMinutes;
      final checkMinutes = startTime.hour * 60 + startTime.minute;
      return checkMinutes >= blockStartMinutes && checkMinutes < blockEndMinutes;
    }).toList();
    
    final updatedStudents = DataManager.instance.students;
    final updatedCellStudents = updatedSelfStudyBlocks.map((b) =>
      updatedStudents.firstWhere(
        (s) => s.student.id == b.studentId,
        orElse: () => StudentWithInfo(
          student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
          basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
        ),
      )
    ).toList();
    
    if (widget.onCellSelfStudyStudentsChanged != null) {
      widget.onCellSelfStudyStudentsChanged!(dayIdx, startTime, updatedCellStudents);
    }
    
    // 자습 블록 수정 로직 호출
    _onSelfStudyBlockMoved(dayIdx, startTime, students);
  }
  
  // 자습 블록 시간 중복 체크
  bool _isSelfStudyTimeOverlap(String studentId, int dayIndex, DateTime startTime, int lessonDurationMinutes) {
    final studentBlocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
    final selfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) => b.studentId == studentId).toList();
    
    final newStart = startTime.hour * 60 + startTime.minute;
    final newEnd = newStart + lessonDurationMinutes;
    
    // 수업 블록 체크
    for (final block in studentBlocks) {
      final blockStart = block.startTime.hour * 60 + block.startTime.minute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        return true;
      }
    }
    
    // 자습 블록 체크 (자신 제외)
    for (final block in selfStudyBlocks) {
      final blockStart = block.startTime.hour * 60 + block.startTime.minute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        return true;
      }
    }
    
    return false;
  }

  // 다중 이동/수정 후
  void exitSelectModeIfNeeded() {
    if (widget.onExitSelectMode != null) {
      widget.onExitSelectMode!();
    }
  }

  // 등록모드에서 수업횟수만큼 등록이 끝나면 자동 종료
  void checkAndExitSelectModeAfterRegistration(int remaining) {
    if (remaining <= 0 && widget.onExitSelectMode != null) {
      widget.onExitSelectMode!();
    }
  }

  void _showClassRegistrationDialog({ClassInfo? editTarget, int? editIndex}) async {
    final result = await showDialog<ClassInfo>(
      context: context,
      builder: (context) => _ClassRegistrationDialog(editTarget: editTarget),
    );
    if (result != null) {
      if (editTarget != null && editIndex != null) {
        // 수정: sessionTypeId 일괄 변경
        await updateSessionTypeIdForClass(editTarget.id, result.id);
        await DataManager.instance.updateClass(result);
      } else {
        await DataManager.instance.addClass(result);
      }
    }
  }

  void _onReorder(int oldIndex, int newIndex) async {
    print('[DEBUG][_onReorder] 시작: oldIndex=$oldIndex, newIndex=$newIndex');
    final classes = List<ClassInfo>.from(DataManager.instance.classesNotifier.value);
    print('[DEBUG][_onReorder] 원본 순서: ${classes.map((c) => c.name).toList()}');
    
    if (oldIndex < newIndex) newIndex--;
    final item = classes.removeAt(oldIndex);
    classes.insert(newIndex, item);
    print('[DEBUG][_onReorder] 변경 후 순서: ${classes.map((c) => c.name).toList()}');
    
    // 즉시 UI 업데이트 (깜빡임 방지)
    DataManager.instance.classesNotifier.value = List.unmodifiable(classes);
    print('[DEBUG][_onReorder] 즉시 UI 업데이트 완료');
    
    // 백그라운드에서 DB 저장
    DataManager.instance.saveClassesOrder(classes).then((_) {
      print('[DEBUG][_onReorder] 백그라운드 DB 저장 완료');
    }).catchError((error) {
      print('[ERROR][_onReorder] DB 저장 실패: $error');
      // DB 저장 실패 시 원래 순서로 복구
      DataManager.instance.loadClasses();
    });
  }

  void _deleteClass(int idx) async {
    final classes = DataManager.instance.classesNotifier.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('수업 삭제', style: TextStyle(color: Colors.white)),
        content: const Text('정말로 이 수업을 삭제하시겠습니까?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final classId = classes[idx].id;
      await clearSessionTypeIdForClass(classId);
      await DataManager.instance.deleteClass(classId);
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
                flex: 1, // 1:1 비율로 수정
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
                          // 수업 등록 버튼
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
                                    Icon(Icons.add, color: Colors.white, size: 20),
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
                      else if (widget.selectedCellDayIndex != null && widget.selectedCellStartTime != null)
                        Expanded(
                          child: ValueListenableBuilder<List<StudentTimeBlock>>(
                            valueListenable: DataManager.instance.studentTimeBlocksNotifier,
                            builder: (context, studentTimeBlocks, _) {
                              return ValueListenableBuilder<List<SelfStudyTimeBlock>>(
                                valueListenable: DataManager.instance.selfStudyTimeBlocksNotifier,
                                builder: (context, selfStudyTimeBlocksRaw, __) {
                                  final selfStudyTimeBlocks = selfStudyTimeBlocksRaw.cast<SelfStudyTimeBlock>();
                                  final blocks = studentTimeBlocks.where((b) =>
                                    b.dayIndex == widget.selectedCellDayIndex &&
                                    b.startTime.hour == widget.selectedCellStartTime!.hour &&
                                    b.startTime.minute == widget.selectedCellStartTime!.minute
                                  ).toList();
                                  final students = DataManager.instance.students;
                                  final cellStudents = blocks.map((b) =>
                                    students.firstWhere(
                                      (s) => s.student.id == b.studentId,
                                      orElse: () => StudentWithInfo(
                                        student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                                        basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
                                      ),
                                    )
                                  ).toList();
                                  // 자습 블록 필터링
                                  print('[DEBUG][자습블록필터링] 전체 자습 블록: ${selfStudyTimeBlocks.length}개');
                                  print('[DEBUG][자습블록필터링] selectedCellDayIndex=${widget.selectedCellDayIndex}, selectedCellStartTime=${widget.selectedCellStartTime}');
                                  final cellSelfStudyBlocks = selfStudyTimeBlocks.where((b) {
                                    final matches = b.dayIndex == widget.selectedCellDayIndex &&
                                        b.startTime.hour == widget.selectedCellStartTime!.hour &&
                                        b.startTime.minute == widget.selectedCellStartTime!.minute;
                                    if (matches) {
                                      print('[DEBUG][자습블록필터링] 매칭된 자습 블록: studentId=${b.studentId}, dayIndex=${b.dayIndex}, startTime=${b.startTime}');
                                    }
                                    return matches;
                                  }).cast<SelfStudyTimeBlock>().toList();
                                  print('[DEBUG][자습블록필터링] 필터링된 자습 블록: ${cellSelfStudyBlocks.length}개');
                                  final cellSelfStudyStudents = cellSelfStudyBlocks.map((b) =>
                                    students.firstWhere(
                                      (s) => s.student.id == b.studentId,
                                      orElse: () => StudentWithInfo(
                                        student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                                        basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
                                      ),
                                    )
                                  ).toList();
                                  
                                  // 학생이 없는 경우 기본 메시지 표시
                                  if (cellStudents.isEmpty && cellSelfStudyStudents.isEmpty) {
                                    return Container(
                                      alignment: Alignment.center,
                                      child: const Text('학생을 검색하거나 셀을 선택하세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
                                    );
                                  }
                                  
                                  return SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (cellStudents.isNotEmpty)
                                          _buildStudentCardList(
                                            cellStudents,
                                            dayTimeLabel: _getDayTimeString(widget.selectedCellDayIndex, widget.selectedCellStartTime),
                                          ),
                                        if (cellSelfStudyStudents.isNotEmpty) ...[
                                          Padding(
                                            padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 8.0),
                                            child: Text(
                                              '자습',
                                              style: const TextStyle(color: Colors.white70, fontSize: 20),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4.0),
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: cellSelfStudyStudents.map<Widget>((info) {
                                                print('[DEBUG][자습카드렌더링] 자습 카드 생성: student=${info.student.name}, dayIndex=${widget.selectedCellDayIndex}, startTime=${widget.selectedCellStartTime}');
                                                return _buildDraggableStudentCard(info, dayIndex: widget.selectedCellDayIndex, startTime: widget.selectedCellStartTime, cellStudents: cellSelfStudyStudents, isSelfStudy: true);
                                              }).toList(),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        )
                      else
                        const Expanded(
                          child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text('학생을 검색하거나 셀을 선택하세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
                              ],
                            ),
                          ),
                        ),
                  // 삭제 드롭존
                  if (_showDeleteZone)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: DragTarget<Map<String, dynamic>>(
                        onWillAccept: (data) => true,
                        onAccept: (data) async {
                          final students = (data['students'] as List<StudentWithInfo>?) ?? [];
                          final oldDayIndex = data['oldDayIndex'] as int?;
                          final oldStartTime = data['oldStartTime'] as DateTime?;
                          final isSelfStudy = data['isSelfStudy'] as bool? ?? false;
                          print('[삭제드롭존] onAccept 호출: students=${students.map((s) => s.student.id).toList()}, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime, isSelfStudy=$isSelfStudy');
                          List<Future> futures = [];
                          
                          if (isSelfStudy) {
                            // 자습 블록 삭제 로직
                            for (final student in students) {
                              print('[삭제드롭존][자습] studentId=${student.student.id}');
                              // 1. 해당 학생+요일+시간 블록 1개 찾기 (setId 추출용)
                              final targetBlock = DataManager.instance.selfStudyTimeBlocks.firstWhere(
                                (b) =>
                                  b.studentId == student.student.id &&
                                  b.dayIndex == oldDayIndex &&
                                  b.startTime.hour == oldStartTime?.hour &&
                                  b.startTime.minute == oldStartTime?.minute,
                                orElse: () => SelfStudyTimeBlock(
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
                                final allBlocks = DataManager.instance.selfStudyTimeBlocks;
                                final toDelete = allBlocks.where((b) => b.setId == targetBlock.setId && b.studentId == student.student.id).toList();
                                for (final b in toDelete) {
                                  print('[삭제드롭존][자습] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}');
                                  futures.add(DataManager.instance.removeSelfStudyTimeBlock(b.id));
                                }
                              }
                              // setId가 없는 경우 단일 블록 삭제
                              final blocks = DataManager.instance.selfStudyTimeBlocks.where((b) =>
                                b.studentId == student.student.id &&
                                b.dayIndex == oldDayIndex &&
                                b.startTime.hour == oldStartTime?.hour &&
                                b.startTime.minute == oldStartTime?.minute
                              ).toList();
                              for (final block in blocks) {
                                print('[삭제드롭존][자습] 삭제 시도: block.id=${block.id}, block.dayIndex=${block.dayIndex}, block.startTime=${block.startTime}');
                                futures.add(DataManager.instance.removeSelfStudyTimeBlock(block.id));
                              }
                            }
                          } else {
                            // 기존 수업 블록 삭제 로직
                            for (final student in students) {
                              print('[삭제드롭존][수업] studentId=${student.student.id}');
                              print('[삭제드롭존][수업] 전체 studentTimeBlocks setId 목록: ' + DataManager.instance.studentTimeBlocks.map((b) => b.setId).toList().toString());
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
                                  print('[삭제드롭존][수업] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}');
                                  futures.add(DataManager.instance.removeStudentTimeBlock(b.id));
                                }
                              }
                              // setId가 없는 경우 단일 블록 삭제
                              final blocks = DataManager.instance.studentTimeBlocks.where((b) =>
                                b.studentId == student.student.id &&
                                b.dayIndex == oldDayIndex &&
                                b.startTime.hour == oldStartTime?.hour &&
                                b.startTime.minute == oldStartTime?.minute
                              ).toList();
                              for (final block in blocks) {
                                print('[삭제드롭존][수업] 삭제 시도: block.id=${block.id}, block.dayIndex=${block.dayIndex}, block.startTime=${block.startTime}');
                                futures.add(DataManager.instance.removeStudentTimeBlock(block.id));
                              }
                            }
                          }
                          
                          await Future.wait(futures);
                          await DataManager.instance.loadStudents();
                          await DataManager.instance.loadStudentTimeBlocks();
                          await DataManager.instance.loadSelfStudyTimeBlocks();
                          setState(() {
                            _showDeleteZone = false;
                          });
                          print('[삭제드롭존] 삭제 후 studentTimeBlocks 개수: ${DataManager.instance.studentTimeBlocks.length}');
                          print('[삭제드롭존] 삭제 후 selfStudyTimeBlocks 개수: ${DataManager.instance.selfStudyTimeBlocks.length}');
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                final blockType = isSelfStudy ? '자습시간' : '수업시간';
                                rootScaffoldMessengerKey.currentState?.showSnackBar(
                                  SnackBar(
                                    content: Text('${students.length}명 학생의 $blockType이 삭제되었습니다.'),
                                    backgroundColor: const Color(0xFF1976D2),
                                    behavior: SnackBarBehavior.floating,
                                    margin: const EdgeInsets.only(bottom: 80, left: 20, right: 20),
                                  ),
                                );
                              }
                            });
                          });
                          // 삭제 후 선택모드 종료 콜백 직접 호출
                          if (widget.onExitSelectMode != null) {
                            widget.onExitSelectMode!();
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
                flex: 1, // 1:1 비율로 수정
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 상단 타이틀 + 버튼 Row
                      Row(
                        children: [
                          // 수업 타이틀 + 스위치
                          Padding(
                            padding: const EdgeInsets.only(top: 12, right: 8),
                            child: Row(
                              children: [
                                Text('수업', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                                SizedBox(width: 6),
                                Tooltip(
                                  message: '수업 등록 모드',
                                  child: Switch(
                                    value: isClassRegisterMode,
                                    onChanged: (val) => setState(() => isClassRegisterMode = val),
                                    activeColor: const Color(0xFF1976D2),
                                    inactiveThumbColor: Colors.white,
                                    inactiveTrackColor: Colors.white24,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          SizedBox(
                            height: 38,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1976D2),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(22),
                                ),
                              ),
                              onPressed: () => _showClassRegistrationDialog(),
                              child: const Row(
                                children: [
                                  Icon(Icons.add, color: Colors.white, size: 20),
                                  SizedBox(width: 6),
                                  Text('수업 관리', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // 수업 카드 리스트
                      Expanded(
                        child: ValueListenableBuilder<List<ClassInfo>>(
                          valueListenable: DataManager.instance.classesNotifier,
                          builder: (context, classes, _) {
                            return classes.isEmpty
                              ? const Center(
                                  child: Text('등록된 수업이 없습니다.', style: TextStyle(color: Colors.white38, fontSize: 16)),
                                )
                              : ReorderableListView.builder(
                                  itemCount: classes.length,
                                  buildDefaultDragHandles: false,
                                  onReorder: _onReorder,
                                  proxyDecorator: (child, index, animation) {
                                    return Material(
                                      color: Colors.transparent,
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
                                        child: child,
                                      ),
                                    );
                                  },
                                  itemBuilder: (context, idx) {
                                    final c = classes[idx];
                                    return _ClassCard(
                                      key: ValueKey(c.id),
                                      classInfo: c,
                                      onEdit: () => _showClassRegistrationDialog(editTarget: c, editIndex: idx),
                                      onDelete: () => _deleteClass(idx),
                                      reorderIndex: idx,
                                      registrationModeType: widget.registrationModeType,
                                    );
                                  },
                                );
                          },
                        ),
                      ),
                    ],
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
  Widget _buildDraggableStudentCard(StudentWithInfo info, {int? dayIndex, DateTime? startTime, List<StudentWithInfo>? cellStudents, bool isSelfStudy = false}) {
    print('[DEBUG][_buildDraggableStudentCard] 호출: student=${info.student.name}, isSelfStudy=$isSelfStudy, dayIndex=$dayIndex, startTime=$startTime');
    // 학생의 고유성을 보장하는 key 생성 (그룹이 있으면 그룹 id까지 포함)
    final cardKey = ValueKey(
      info.student.id + (info.student.groupInfo?.id ?? ''),
    );
    final isSelected = widget.selectedStudentIds.contains(info.student.id);
    // 선택된 학생 리스트
    final selectedStudents = cellStudents?.where((s) => widget.selectedStudentIds.contains(s.student.id)).toList() ?? [];
    final selectedCount = selectedStudents.length;
    return Stack(
      children: [
        Draggable<Map<String, dynamic>>(
          data: {
            'type': isClassRegisterMode ? 'register' : 'move',
            'students': isSelected && selectedCount > 1 ? selectedStudents : [info],
            'student': info,
            'oldDayIndex': dayIndex,
            'oldStartTime': startTime,
            'isSelfStudy': isSelfStudy,
          },
          onDragStarted: () {
            print('[DEBUG][Draggable] onDragStarted: studentTimeBlocks.length=${DataManager.instance.studentTimeBlocks.length}');
            print('[DEBUG][_buildDraggableStudentCard] 드래그 시작: student= [36m${info.student.name} [0m, isSelfStudy=$isSelfStudy');
            setState(() => _showDeleteZone = true);
          },
          onDragEnd: (_) {
            print('[DEBUG][Draggable] onDragEnd: studentTimeBlocks.length=${DataManager.instance.studentTimeBlocks.length}');
            setState(() => _showDeleteZone = false);
          },
          feedback: _buildDragFeedback(selectedStudents, info),
          childWhenDragging: Opacity(
            opacity: 0.3,
            child: StudentCard(
              key: cardKey,
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
            key: cardKey,
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
        Positioned.fill(
          child: Draggable<Map<String, dynamic>>(
            data: {
              'type': 'register',
              'student': info,
            },
            feedback: _buildDragFeedback(selectedStudents, info),
            childWhenDragging: const SizedBox.shrink(),
            child: Container(), // 투명 오버레이(실제 UI는 아래 StudentCard)
          ),
        ),
      ],
    );
  }

  Widget _buildDragFeedback(List<StudentWithInfo> selectedStudents, StudentWithInfo mainInfo) {
    final count = selectedStudents.length;
    if (count <= 1) {
      // 기존 단일 카드 피드백
      return Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: StudentCard(
            studentWithInfo: mainInfo,
            onShowDetails: (_) {},
            showCheckbox: true,
            checked: true,
          ),
        ),
      );
    } else if (count <= 3) {
      // 2~3개: 카드 쌓임, 맨 위만 내용, 나머지는 빈 카드
      return Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 120 + 16.0 * (count - 1),
          height: 50,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: List.generate(count, (i) =>
              Positioned(
                left: i * 16.0,
                child: Opacity(
                  opacity: 0.85 - i * 0.18,
                  child: SizedBox(
                    width: 120,
                    child: i == count - 1
                      ? StudentCard(
                          studentWithInfo: selectedStudents[i],
                          onShowDetails: (_) {},
                          showCheckbox: true,
                          checked: true,
                        )
                      : _buildEmptyCard(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      // 4개 이상: 카드 쌓임 + 개수 표시(중앙, 검정 배경, 회색 글씨)
      return Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 120 + 16.0 * 2, // 3장 겹침 + 개수
          height: 50,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              ...List.generate(3, (i) =>
                Positioned(
                  left: i * 16.0,
                  child: Opacity(
                    opacity: 0.85 - i * 0.18,
                    child: SizedBox(
                      width: 120,
                      child: i == 2
                        ? StudentCard(
                            studentWithInfo: selectedStudents[i],
                            onShowDetails: (_) {},
                            showCheckbox: true,
                            checked: true,
                          )
                        : _buildEmptyCard(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 48.0,
                child: Container(
                  width: 120,
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black26, width: 1.2),
                  ),
                  child: Text(
                    '+${count}',
                    style: const TextStyle(
                      color: Color(0xFFB0B0B0),
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildEmptyCard() {
    return Container(
      width: 120,
      height: 50,
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.13),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.black26, width: 1.2),
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
    // 1. 학생별로 해당 시간에 속한 StudentTimeBlock을 찾아 sessionTypeId로 분류
    final studentBlocks = DataManager.instance.studentTimeBlocks;
    final selectedDayIdx = widget.selectedCellDayIndex;
    final selectedStartTime = widget.selectedCellStartTime;
    final Map<String, String?> studentSessionTypeMap = {
      for (var s in students)
        s.student.id: (() {
          final block = studentBlocks.firstWhere(
            (b) => b.studentId == s.student.id && b.dayIndex == selectedDayIdx && b.startTime.hour == selectedStartTime?.hour && b.startTime.minute == selectedStartTime?.minute,
            orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startTime: DateTime(0), duration: Duration.zero, createdAt: DateTime(0)),
          );
          return block.id.isEmpty ? null : block.sessionTypeId;
        })()
    };
    final noSession = <StudentWithInfo>[];
    final sessionMap = <String, List<StudentWithInfo>>{};
    for (final s in students) {
      final sessionId = studentSessionTypeMap[s.student.id];
      if (sessionId == null || sessionId.isEmpty) {
        noSession.add(s);
      } else {
        sessionMap.putIfAbsent(sessionId, () => []).add(s);
      }
    }
    noSession.sort((a, b) => a.student.name.compareTo(b.student.name));
    final classCards = DataManager.instance.classes;
    final sessionOrder = classCards.map((c) => c.id).toList();
    final orderedSessionIds = sessionOrder.where((id) => sessionMap.containsKey(id)).toList();
    final unorderedSessionIds = sessionMap.keys.where((id) => !sessionOrder.contains(id)).toList();
    final allSessionIds = [...orderedSessionIds, ...unorderedSessionIds];
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
        if (noSession.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: noSession.map((info) =>
                _buildDraggableStudentCard(info, dayIndex: widget.selectedCellDayIndex, startTime: widget.selectedCellStartTime, cellStudents: students)
              ).toList(),
            ),
          ),
        for (final sessionId in allSessionIds)
          if (sessionMap[sessionId] != null && sessionMap[sessionId]!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      (() {
                        final c = classCards.firstWhere(
                          (c) => c.id == sessionId,
                          orElse: () => ClassInfo(id: '', name: '', color: null, description: '', capacity: null),
                        );
                        return c.id.isEmpty ? '수업' : c.name;
                      })(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: (() {
                      final sessionStudents = sessionMap[sessionId]!;
                      sessionStudents.sort((a, b) => a.student.name.compareTo(b.student.name));
                      return sessionStudents.map((info) => _buildDraggableStudentCard(info, dayIndex: widget.selectedCellDayIndex, startTime: widget.selectedCellStartTime, cellStudents: students)).toList();
                    })(),
                  ),
                ],
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
      // number==1인 블록만 필터링
      final studentBlocks = blocks.where((b) => b.studentId == student.student.id && (b.number == null || b.number == 1)).toList();
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

  // --- 셀 클릭 시 검색 내역 초기화 ---
  @override
  void didUpdateWidget(covariant TimetableContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 셀 선택이 바뀌면 검색 내역 초기화
    if ((widget.selectedCellDayIndex != oldWidget.selectedCellDayIndex) || (widget.selectedCellStartTime != oldWidget.selectedCellStartTime)) {
      clearSearch();
    }
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

// 수업 등록 다이얼로그 (그룹등록 다이얼로그 참고)
class _ClassRegistrationDialog extends StatefulWidget {
  final ClassInfo? editTarget;
  const _ClassRegistrationDialog({this.editTarget});
  @override
  State<_ClassRegistrationDialog> createState() => _ClassRegistrationDialogState();
}

class _ClassRegistrationDialogState extends State<_ClassRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _capacityController;
  Color? _selectedColor;
  bool _unlimitedCapacity = false;
  final List<Color?> _colors = [null, ...Colors.primaries];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.editTarget?.name ?? '');
    _descController = TextEditingController(text: widget.editTarget?.description ?? '');
    _capacityController = TextEditingController(text: widget.editTarget?.capacity?.toString() ?? '');
    _selectedColor = widget.editTarget?.color;
    _unlimitedCapacity = widget.editTarget?.capacity == null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final desc = _descController.text.trim();
    final capacity = _unlimitedCapacity ? null : int.tryParse(_capacityController.text.trim());
    if (name.isEmpty) {
      showAppSnackBar(context, '수업명을 입력하세요');
      return;
    }
    Navigator.of(context).pop(ClassInfo(
      id: widget.editTarget?.id ?? UniqueKey().toString(),
      name: name,
      capacity: capacity,
      description: desc,
      color: _selectedColor,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(widget.editTarget == null ? '수업 등록' : '수업 수정', style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '수업명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _capacityController,
                    enabled: !_unlimitedCapacity,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '정원',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Checkbox(
                  value: _unlimitedCapacity,
                  onChanged: (v) => setState(() => _unlimitedCapacity = v ?? false),
                  checkColor: Colors.white,
                  activeColor: const Color(0xFF1976D2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                const Text('제한없음', style: TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '설명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),
            const Text('수업 색상', style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
                final isSelected = _selectedColor == color;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color ?? Colors.transparent,
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.white24,
                        width: isSelected ? 2.5 : 1.2,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: color == null
                        ? const Center(child: Icon(Icons.close_rounded, color: Colors.white54, size: 18))
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: Text(widget.editTarget == null ? '등록' : '수정'),
        ),
      ],
    );
  }
}

// 수업카드 위젯 (그룹카드 스타일 참고)
class _ClassCard extends StatefulWidget {
  final ClassInfo classInfo;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final int reorderIndex;
  final String? registrationModeType;
  const _ClassCard({Key? key, required this.classInfo, required this.onEdit, required this.onDelete, required this.reorderIndex, this.registrationModeType}) : super(key: key);
  @override
  State<_ClassCard> createState() => _ClassCardState();
}

class _ClassCardState extends State<_ClassCard> {
  bool _isHovering = false;

  Future<void> _handleStudentDrop(StudentWithInfo studentWithInfo) async {
    final blocks = DataManager.instance.studentTimeBlocks
      .where((b) => b.studentId == studentWithInfo.student.id)
      .toList();
    if (blocks.isEmpty) return;
    final setId = blocks.first.setId;
    if (setId == null) return;
    final targetBlocks = blocks.where((b) => b.setId == setId && b.studentId == studentWithInfo.student.id).toList();
    for (final block in targetBlocks) {
      final updated = block.copyWith(sessionTypeId: widget.classInfo.id);
      print('[DEBUG][_handleStudentDrop] update block: id=${block.id}, sessionTypeId=${widget.classInfo.id}');
      await DataManager.instance.updateStudentTimeBlock(block.id, updated);
    }
    // 드롭 후 최신화
    await DataManager.instance.loadStudentTimeBlocks();
    print('[DEBUG][_ClassCard.build] 전체 studentTimeBlocks=' + DataManager.instance.studentTimeBlocks.map((b) => '${b.studentId}:${b.sessionTypeId}').toList().toString());
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.classInfo;
    final int studentCount = DataManager.instance.getStudentCountForClass(widget.classInfo.id);
    print('[DEBUG][_ClassCard.build] 전체 studentTimeBlocks=' + DataManager.instance.studentTimeBlocks.map((b) => '${b.studentId}:${b.sessionTypeId}').toList().toString());
    return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        print('[DEBUG][DragTarget] onWillAccept: data= [33m$data [0m');
        // registrationModeType이 null(등록모드 아님)일 때만 허용 + type이 'register'일 때만 허용
        if (widget.registrationModeType != null) return false;
        if (data == null || data['type'] != 'register') return false;
        final max = widget.classInfo.capacity;
        final current = DataManager.instance.getStudentCountForClass(widget.classInfo.id);
        final isFull = max != null && current >= max;
        if (isFull) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('정원이 가득 찼습니다.', style: TextStyle(color: Colors.white)), backgroundColor: Colors.red, duration: Duration(seconds: 1)),
          );
          return false;
        }
        return true;
      },
      onAccept: (data) async {
        print('[DEBUG][DragTarget] onAccept: data= [32m$data [0m');
        setState(() => _isHovering = false);
        final studentWithInfo = data['student'] as StudentWithInfo?;
        if (studentWithInfo != null) {
          await _handleStudentDrop(studentWithInfo);
        }
      },
      onMove: (_) {
        print('[DEBUG][DragTarget] onMove');
        setState(() => _isHovering = true);
      },
      onLeave: (_) {
        print('[DEBUG][DragTarget] onLeave');
        setState(() => _isHovering = false);
      },
      builder: (context, candidateData, rejectedData) {
        print('[DEBUG][DragTarget] builder: candidateData=$candidateData, rejectedData=$rejectedData, _isHovering=$_isHovering');
        return Card(
          key: widget.key,
          color: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: _isHovering
              ? BorderSide(color: c.color ?? const Color(0xFFB0B0B0), width: 2.5)
              : const BorderSide(color: Colors.transparent, width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.only(right: 14),
                      decoration: BoxDecoration(
                        color: c.color ?? const Color(0xFF1F1F1F),
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: Colors.white24, width: 1.4),
                      ),
                      // 색상이 없을 때 X 아이콘을 표시하지 않음
                      // child: c.color == null
                      //   ? const Center(child: Icon(Icons.close_rounded, color: Colors.white54, size: 14))
                      //   : null,
                    ),
                    Expanded(
                      child: Text(
                        c.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                      onPressed: widget.onEdit,
                      tooltip: '수정',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.white70, size: 20),
                      onPressed: widget.onDelete,
                      tooltip: '삭제',
                    ),
                    const SizedBox(width: 4),
                    ReorderableDragStartListener(
                      index: widget.reorderIndex,
                      child: const Icon(Icons.drag_handle, color: Colors.white38, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        c.description.isEmpty ? '-' : c.description,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      c.capacity == null
                        ? '$studentCount/제한없음'
                        : '$studentCount/${c.capacity}명',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
} 

// TimetableContentViewState 내부에 아래 메서드 추가
// (적절한 위치에 삽입)

  // 수업카드 수정 시 관련 StudentTimeBlock의 session_type_id 일괄 수정
  Future<void> updateSessionTypeIdForClass(String oldClassId, String newClassId) async {
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.sessionTypeId == oldClassId).toList();
    for (final block in blocks) {
      final updated = block.copyWith(sessionTypeId: newClassId);
      await DataManager.instance.updateStudentTimeBlock(block.id, updated);
    }
  }

  // 수업카드 삭제 시 관련 StudentTimeBlock의 session_type_id를 null로 초기화
  Future<void> clearSessionTypeIdForClass(String classId) async {
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.sessionTypeId == classId).toList();
    for (final block in blocks) {
      final updated = block.copyWith(sessionTypeId: null);
      await DataManager.instance.updateStudentTimeBlock(block.id, updated);
    }
  } 