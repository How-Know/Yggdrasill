import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/student_card.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../main.dart'; // rootScaffoldMessengerKey import
import '../../../models/student_time_block.dart';
import '../../../models/self_study_time_block.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../models/class_info.dart';
import 'package:uuid/uuid.dart';
import '../views/makeup_view.dart';
import '../../../models/session_override.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class TimetableContentView extends StatefulWidget {
  final Widget timetableChild;
  final VoidCallback onRegisterPressed;
  final String splitButtonSelected;
  final bool isDropdownOpen;
  final ValueChanged<bool> onDropdownOpenChanged;
  final ValueChanged<String> onDropdownSelected;
  final int? selectedCellDayIndex;
  final DateTime? selectedCellStartTime;
  final DateTime? selectedDayDate; // 요일 클릭 시 선택된 날짜(주 기준)
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)? onCellStudentsChanged;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)? onCellSelfStudyStudentsChanged;
  final VoidCallback? clearSearch; // 추가: 외부에서 검색 리셋 요청
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;
  final VoidCallback? onExitSelectMode; // 추가: 다중모드 종료 콜백
  final String? registrationModeType;
  final Set<String>? filteredStudentIds; // 추가: 필터링된 학생 ID 목록
  final String? placeholderText; // 빈 셀 안내 문구 대체용

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
    this.selectedDayDate,
    this.onCellStudentsChanged,
    this.onCellSelfStudyStudentsChanged,
    this.clearSearch, // 추가
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
    this.onExitSelectMode,
    this.registrationModeType,
    this.filteredStudentIds, // 추가
    this.placeholderText,
  }) : super(key: key);

  @override
  State<TimetableContentView> createState() => TimetableContentViewState();
}

class TimetableContentViewState extends State<TimetableContentView> {
  // 메모 오버레이가 사용할 전역 키 등을 두려면 이곳에 배치 가능 (현재 오버레이는 TimetableScreen에서 처리)
  final GlobalKey _dropdownButtonKey = GlobalKey();
  OverlayEntry? _dropdownOverlay;
  bool _showDeleteZone = false;
  Future<void> _showMakeupListDialog() async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1F1F1F),
          insetPadding: const EdgeInsets.fromLTRB(42, 42, 42, 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 1104, // 920 * 1.2
            height: 800, // 640 * 1.2
            child: const MakeupView(),
          ),
        );
      },
    );
  }
  String _searchQuery = '';
  List<StudentWithInfo> _searchResults = [];
  final TextEditingController _searchController = ImeAwareTextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearchExpanded = false;
  bool isClassRegisterMode = false;

  String _weekdayLabel(int dayIdx) {
    const labels = ['월', '화', '수', '목', '금', '토', '일'];
    return labels[dayIdx.clamp(0, 6)];
  }

  @override
  void initState() {
    super.initState();
    DataManager.instance.loadClasses();
    // 🧹 앱 시작 시 삭제된 수업의 sessionTypeId를 가진 블록들 정리
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _diagnoseOrphanedSessionTypeIds(); // 진단 먼저
      await cleanupOrphanedSessionTypeIds();
      await _diagnoseOrphanedSessionTypeIds(); // 정리 후 다시 확인
    });
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
                ...['학생', '수업'].map((label) => _DropdownMenuHoverItem(
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

  void _removeDropdownMenu([bool notify = true]) {
    _dropdownOverlay?.remove();
    _dropdownOverlay = null;
    if (notify) {
      widget.onDropdownOpenChanged(false);
    }
  }

  // 외부에서 수업 등록 다이얼로그를 열 수 있도록 공개 메서드
  void openClassRegistrationDialog() {
    _showClassRegistrationDialog();
  }

  @override
  void dispose() {
    // dispose 중에는 부모 setState를 유발하지 않도록 notify=false
    _removeDropdownMenu(false);
    _searchFocusNode.dispose();
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
      b.startHour == startTime.hour &&
      b.startMinute == startTime.minute
    ).toList();
    final updatedStudents = DataManager.instance.students;
    final updatedCellStudents = updatedBlocks.map((b) =>
      updatedStudents.firstWhere(
        (s) => s.student.id == b.studentId,
        orElse: () => StudentWithInfo(
          student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
          basicInfo: StudentBasicInfo(studentId: ''),
        ),
      )
    ).toList();
    if (widget.onCellStudentsChanged != null) {
      widget.onCellStudentsChanged!(dayIdx, startTime, updatedCellStudents);
    }
  }

  // 자습 블록 수정 (셀 위에 드롭)
  void _onSelfStudyBlockMoved(int dayIdx, DateTime startTime, List<StudentWithInfo> students) async {
    // print('[DEBUG][_onSelfStudyBlockMoved] 호출: dayIdx=$dayIdx, startTime=$startTime, students=${students.map((s) => s.student.name).toList()}');
    
    // 이동할 자습 블록들 찾기 (현재 선택된 셀의 자습 블록들)
    final currentSelfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) {
      if (b.dayIndex != widget.selectedCellDayIndex || widget.selectedCellStartTime == null) return false;
      final blockStartMinutes = b.startHour * 60 + b.startMinute;
      final blockEndMinutes = blockStartMinutes + b.duration.inMinutes;
      final checkMinutes = widget.selectedCellStartTime!.hour * 60 + widget.selectedCellStartTime!.minute;
      return checkMinutes >= blockStartMinutes && checkMinutes < blockEndMinutes;
    }).toList();
    
    if (currentSelfStudyBlocks.isEmpty) {
      // print('[DEBUG][_onSelfStudyBlockMoved] 이동할 자습 블록이 없음');
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
        startHour: startTime.hour,
        startMinute: startTime.minute,
      );
      await DataManager.instance.updateSelfStudyTimeBlock(block.id, newBlock);
    }
    
    // UI 업데이트
    final updatedSelfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) {
      if (b.dayIndex != dayIdx) return false;
      final blockStartMinutes = b.startHour * 60 + b.startMinute;
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
          basicInfo: StudentBasicInfo(studentId: ''),
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
      final blockStart = block.startHour * 60 + block.startMinute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        return true;
      }
    }
    
    // 자습 블록 체크 (자신 제외)
    for (final block in selfStudyBlocks) {
      final blockStart = block.startHour * 60 + block.startMinute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        return true;
      }
    }
    
    return false;
  }

  // 다중 이동/수정 후
  void exitSelectModeIfNeeded() {
    print('[DEBUG][exitSelectModeIfNeeded] 호출됨, onExitSelectMode != null: ${widget.onExitSelectMode != null}');
    if (widget.onExitSelectMode != null) {
      print('[DEBUG][exitSelectModeIfNeeded] 선택 모드 종료 콜백 실행');
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
    // print('[DEBUG][_onReorder] 시작: oldIndex=$oldIndex, newIndex=$newIndex');
    final classes = List<ClassInfo>.from(DataManager.instance.classesNotifier.value);
    // print('[DEBUG][_onReorder] 원본 순서: ${classes.map((c) => c.name).toList()}');
    
    if (oldIndex < newIndex) newIndex--;
    final item = classes.removeAt(oldIndex);
    classes.insert(newIndex, item);
    // print('[DEBUG][_onReorder] 변경 후 순서: ${classes.map((c) => c.name).toList()}');
    
    // 즉시 UI 업데이트 (깜빡임 방지)
    DataManager.instance.classesNotifier.value = List.unmodifiable(classes);
    // print('[DEBUG][_onReorder] 즉시 UI 업데이트 완료');
    
    // 백그라운드에서 DB 저장
    DataManager.instance.saveClassesOrder(classes).then((_) {
      // print('[DEBUG][_onReorder] 백그라운드 DB 저장 완료');
    }).catchError((error) {
      // print('[ERROR][_onReorder] DB 저장 실패: $error');
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
    return Row(
      children: [
        const SizedBox(width: 24),
        Expanded(
          flex: 3,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                height: constraints.maxHeight,
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 0), // vertical 32 -> 16으로 조정
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: widget.timetableChild,
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                flex: 1, // 1:1 비율로 수정
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, right: 8, top: 8, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Builder(builder: (context) {
                        final screenW = MediaQuery.of(context).size.width;
                        final isNarrow = screenW <= 1600;
                        if (isNarrow) {
                          // 좁은 화면: 좌우 1:1 영역으로 분할 + 화면 너비에 비례한 크기 조정
                          final double t = ((screenW - 1200) / 400).clamp(0.0, 1.0);
                          final double h = 30 + (38 - 30) * t; // 1200px에서 30 → 1600px에서 38
                          final double regW = 80 + (96 - 80) * t; // 등록 버튼 너비 80~96
                          final double dropW = 30 + (38 - 30) * t; // 드롭다운 30~38
                          final double dividerLineH = 16 + (22 - 16) * t; // 구분선 내부 라인 16~22
                          final double searchW = 120 + (160 - 120) * t; // 검색바 너비 120~160
                          return Row(
                            children: [
                              Expanded(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    // 수업 등록 버튼 (협소 화면 추가 축소)
                                    SizedBox(
                                      width: regW,
                                      height: h,
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
                                              Icon(Icons.add, color: Colors.white, size: 16),
                                              SizedBox(width: 6),
                                              Text('등록', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    // 구분선
                                    Container(
                                      height: h,
                                      width: 3.0,
                                      color: Colors.transparent,
                                      child: Center(
                                        child: Container(
                                          width: 2,
                                          height: dividerLineH,
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
                                          width: dropW,
                                          height: h,
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
                                                size: 20,
                                                key: ValueKey('arrow'),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // 보강 버튼 (아이콘만, 등록 버튼 색상과 동일)
                                    SizedBox(
                                      height: h,
                                      child: Material(
                                        color: const Color(0xFF1976D2),
                                        borderRadius: BorderRadius.circular(8),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(8),
                                          onTap: () {},
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 12.0),
                                            child: Icon(Icons.event_repeat_rounded, color: Colors.white, size: 20),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // 검색 버튼 (학생메뉴와 동일한 애니메이션)
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 250),
                                      height: h,
                                      width: _isSearchExpanded ? searchW : h,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2A2A),
                                        borderRadius: BorderRadius.circular(h/2),
                                        border: Border.all(color: Colors.white.withOpacity(0.2)),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: _isSearchExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                            padding: _isSearchExpanded ? const EdgeInsets.only(left: 8) : EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            icon: const Icon(Icons.search, color: Colors.white70, size: 20),
                                            onPressed: () {
                                              setState(() { _isSearchExpanded = !_isSearchExpanded; });
                                              if (_isSearchExpanded) {
                                                Future.delayed(const Duration(milliseconds: 50), () { _searchFocusNode.requestFocus(); });
                                              } else {
                                                setState(() { _searchController.clear(); _searchQuery = ''; });
                                                FocusScope.of(context).unfocus();
                                              }
                                            },
                                          ),
                                          if (_isSearchExpanded) const SizedBox(width: 10),
                                          if (_isSearchExpanded)
                                            SizedBox(
                                              width: searchW - 50,
                                              child: TextField(
                                                controller: _searchController,
                                                focusNode: _searchFocusNode,
                                                style: const TextStyle(color: Colors.white, fontSize: 16.5),
                                                decoration: const InputDecoration(
                                                  hintText: '검색',
                                                  hintStyle: TextStyle(color: Colors.white54, fontSize: 16.5),
                                                  border: InputBorder.none,
                                                  isDense: true,
                                                  contentPadding: EdgeInsets.zero,
                                                ),
                                                onChanged: _onSearchChanged,
                                              ),
                                            ),
                                          if (_isSearchExpanded && _searchQuery.isNotEmpty)
                                            IconButton(
                                              visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                              padding: const EdgeInsets.only(right: 10),
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                              tooltip: '지우기',
                                              icon: const Icon(Icons.clear, color: Colors.white70, size: 16),
                                              onPressed: () {
                                                setState(() { _searchController.clear(); _searchQuery = ''; });
                                                FocusScope.of(context).requestFocus(_searchFocusNode);
                                              },
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // 우측 영역 제거: 모든 버튼을 왼쪽 정렬
                            ],
                          );
                        }
                        // 넓은 화면: 기존 레이아웃 유지
                        return Row(
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
                          const SizedBox(width: 6),
                          // 보강 버튼 (아이콘만, 강조 색상, 툴팁)
                          Tooltip(
                            message: '보강',
                            child: SizedBox(
                              height: 44,
                              child: Material(
                                color: const Color(0xFF1565C0), // 기존보다 약간 진하게
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _showMakeupListDialog,
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                                    child: Icon(Symbols.push_pin_rounded, color: Colors.white, size: 22, weight: 600, opticalSize: 48),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 검색 버튼 (학생메뉴와 동일한 애니메이션, 왼쪽 정렬)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            height: 44,
                            width: _isSearchExpanded ? 160 : 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(color: Colors.white.withOpacity(0.2)),
                            ),
                            child: Row(
                              mainAxisAlignment: _isSearchExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                IconButton(
                                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                  padding: _isSearchExpanded ? const EdgeInsets.only(left: 8) : EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  icon: const Icon(Icons.search, color: Colors.white70, size: 20),
                                  onPressed: () {
                                    setState(() { _isSearchExpanded = !_isSearchExpanded; });
                                    if (_isSearchExpanded) {
                                      Future.delayed(const Duration(milliseconds: 50), () { _searchFocusNode.requestFocus(); });
                                    } else {
                                      setState(() { _searchController.clear(); _searchQuery = ''; });
                                      FocusScope.of(context).unfocus();
                                    }
                                  },
                                ),
                                if (_isSearchExpanded) const SizedBox(width: 10),
                                if (_isSearchExpanded)
                                  Expanded(
                                    child: TextField(
                                      controller: _searchController,
                                      focusNode: _searchFocusNode,
                                      style: const TextStyle(color: Colors.white, fontSize: 16.5),
                                      decoration: const InputDecoration(
                                        hintText: '검색',
                                        hintStyle: TextStyle(color: Colors.white54, fontSize: 16.5),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onChanged: _onSearchChanged,
                                    ),
                                  ),
                                if (_isSearchExpanded && _searchQuery.isNotEmpty)
                                  IconButton(
                                    visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                    padding: const EdgeInsets.only(right: 10),
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    tooltip: '지우기',
                                    icon: const Icon(Icons.clear, color: Colors.white70, size: 16),
                                    onPressed: () {
                                      setState(() { _searchController.clear(); _searchQuery = ''; });
                                      FocusScope.of(context).requestFocus(_searchFocusNode);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                      }),
                      // 학생카드 리스트 위에 요일+시간 출력
                      Expanded(
                        child: _searchQuery.isNotEmpty && _searchResults.isNotEmpty
                          ? SingleChildScrollView(
                              child: _buildGroupedStudentCardsByDayTime(_searchResults),
                            )
                          : (
                              // 1) 셀 선택 시: 해당 시간 학생카드
                              (widget.selectedCellDayIndex != null && widget.selectedCellStartTime != null)
                                ? ValueListenableBuilder<List<StudentTimeBlock>>(
                                    valueListenable: DataManager.instance.studentTimeBlocksNotifier,
                                    builder: (context, studentTimeBlocks, _) {
                                      return ValueListenableBuilder<List<SelfStudyTimeBlock>>(
                                        valueListenable: DataManager.instance.selfStudyTimeBlocksNotifier,
                                        builder: (context, selfStudyTimeBlocksRaw, __) {
                                  final selfStudyTimeBlocks = selfStudyTimeBlocksRaw.cast<SelfStudyTimeBlock>();
                                  final blocks = studentTimeBlocks.where((b) =>
                                    b.dayIndex == widget.selectedCellDayIndex &&
                                    b.startHour == widget.selectedCellStartTime!.hour &&
                                    b.startMinute == widget.selectedCellStartTime!.minute
                                  ).toList();
                                  // 보강 원본 블라인드(set_id 우선): 같은 날짜(YMD)의 replace 원본이 있으면 해당 (studentId,setId) 전체를 제외
                                  final DateTime weekStart = DateTime(widget.selectedCellStartTime!.year, widget.selectedCellStartTime!.month, widget.selectedCellStartTime!.day)
                                      .subtract(Duration(days: widget.selectedCellStartTime!.weekday - DateTime.monday));
                                  final DateTime weekEnd = weekStart.add(const Duration(days: 7));
                                  final int selDayIdx = widget.selectedCellDayIndex ?? 0; // 0=월
                                  final DateTime cellYmd = weekStart.add(Duration(days: selDayIdx));
                                  final DateTime cellDate = DateTime(
                                    cellYmd.year,
                                    cellYmd.month,
                                    cellYmd.day,
                                    widget.selectedCellStartTime!.hour,
                                    widget.selectedCellStartTime!.minute,
                                  );
                                  final Set<String> hiddenPairs = {};
                                  for (final ov in DataManager.instance.sessionOverrides) {
                                    if (ov.reason != OverrideReason.makeup) continue;
                                    if (ov.overrideType != OverrideType.replace) continue;
                                    if (ov.status == OverrideStatus.canceled) continue;
                                    final orig = ov.originalClassDateTime;
                                    if (orig == null) continue;
                                    if (orig.isBefore(weekStart) || !orig.isBefore(weekEnd)) continue;
                                    final bool sameYmd = orig.year == cellDate.year && orig.month == cellDate.month && orig.day == cellDate.day;
                                    if (!sameYmd) continue;
                                    String? setId = ov.setId;
                                    if (setId == null || setId.isEmpty) {
                                      // 학생의 같은 요일 블록에서 원본 시간과 가장 가까운 블록의 setId 추정
                                      final blocksByStudent = studentTimeBlocks.where((b) => b.studentId == ov.studentId && b.dayIndex == widget.selectedCellDayIndex).toList();
                                      if (blocksByStudent.isNotEmpty) {
                                        int origMin = orig.hour * 60 + orig.minute;
                                        int bestDiff = 1 << 30;
                                        for (final b in blocksByStudent) {
                                          final int bm = b.startHour * 60 + b.startMinute;
                                          final int diff = (bm - origMin).abs();
                                          if (diff < bestDiff && b.setId != null && b.setId!.isNotEmpty) {
                                            bestDiff = diff;
                                            setId = b.setId;
                                          }
                                        }
                                      }
                                    }
                                    if (setId != null && setId.isNotEmpty) {
                                      hiddenPairs.add('${ov.studentId}|$setId');
                                    }
                                  }
                                  // DIAG: hiddenPairs 요약 출력(있을 때만)
                                  if (hiddenPairs.isNotEmpty) {
                                    // ignore: avoid_print
                                    print('[BLIND][list] cell=${cellDate.toString().substring(0,16)} hiddenPairs=$hiddenPairs');
                                  }
                                  final selectedDate = widget.selectedCellStartTime!;
                                  final studentIdSet = (widget.filteredStudentIds ?? DataManager.instance.students.map((s) => s.student.id).toList()).toSet();
                                  List<StudentTimeBlock> filteredBlocks = [];
                                  for (final b in blocks) {
                                    if (!studentIdSet.contains(b.studentId)) continue;
                                    final pairKey = '${b.studentId}|${b.setId ?? ''}';
                                    if (hiddenPairs.isNotEmpty) {
                                      final hit = hiddenPairs.contains(pairKey);
                                      // ignore: avoid_print
                                      print('[BLIND][list] check pairKey=$pairKey setId=${b.setId} hit=$hit');
                                    }
                                    if (hiddenPairs.contains(pairKey)) {
                                      continue; // set_id 블라인드 적용
                                    }
                                    // 주차 계산 (등록일 기반)
                                    DateTime? reg;
                                    try { reg = DataManager.instance.students.firstWhere((s) => s.student.id == b.studentId).basicInfo.registrationDate; } catch (_) { reg = null; }
                                    if (reg == null) { filteredBlocks.add(b); continue; }
                                    DateTime toMonday(DateTime x) { final off = x.weekday - DateTime.monday; return DateTime(x.year, x.month, x.day).subtract(Duration(days: off)); }
                                    final week = (() { final rm = toMonday(reg!); final sm = toMonday(selectedDate); final diff = sm.difference(rm).inDays; return (diff >= 0 ? (diff ~/ 7) : 0) + 1; })();
                                    final startMin = b.startHour * 60 + b.startMinute;
                                    final blind = _shouldBlindBlock(
                                      studentId: b.studentId,
                                      weekNumber: week,
                                      weeklyOrder: b.weeklyOrder,
                                      sessionTypeId: b.sessionTypeId,
                                      dayIdx: b.dayIndex,
                                      startMin: startMin,
                                    );
                                    if (!blind) filteredBlocks.add(b);
                                  }
                                  final blocksToUse = filteredBlocks;
                                  final allStudents = DataManager.instance.students;
                                  // print('[DEBUG][학생카드리스트] 전체 학생 수: ${allStudents.length}');
                                  // print('[DEBUG][학생카드리스트] 필터링된 학생 ID: ${widget.filteredStudentIds}');
                                  // print('[DEBUG][학생카드리스트] 해당 셀의 블록 수(필터 전): ${blocks.length}, (블라인드 후): ${blocksToUse.length}');
                                  
                                  // 필터링 적용: 필터가 있으면 필터링된 학생만, 없으면 전체 학생
                                  final students = widget.filteredStudentIds == null 
                                    ? allStudents 
                                    : allStudents.where((s) => widget.filteredStudentIds!.contains(s.student.id)).toList();
                                  // print('[DEBUG][학생카드리스트] 필터링 후 학생 수: ${students.length}');
                                  
                                  final cellStudents = blocksToUse.map((b) =>
                                    students.firstWhere(
                                      (s) => s.student.id == b.studentId,
                                      orElse: () => StudentWithInfo(
                                        student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                                        basicInfo: StudentBasicInfo(studentId: ''),
                                      ),
                                    )
                                  ).where((s) => s.student.id.isNotEmpty).toList(); // 빈 학생 제거
                                  // print('[DEBUG][학생카드리스트] 최종 셀 학생 수: ${cellStudents.length}');
                                  // print('[DEBUG][학생카드리스트] 최종 셀 학생 이름들: ${cellStudents.map((s) => s.student.name).toList()}');
                                  // 자습 블록 필터링
                                  // print('[DEBUG][자습블록필터링] 전체 자습 블록: ${selfStudyTimeBlocks.length}개');
                                  // print('[DEBUG][자습블록필터링] selectedCellDayIndex=${widget.selectedCellDayIndex}, selectedCellStartTime=${widget.selectedCellStartTime}');
                                  final cellSelfStudyBlocks = selfStudyTimeBlocks.where((b) {
                                    final matches = b.dayIndex == widget.selectedCellDayIndex &&
                                        b.startHour == widget.selectedCellStartTime!.hour &&
                                        b.startMinute == widget.selectedCellStartTime!.minute;
                                    if (matches) {
                                      // print('[DEBUG][자습블록필터링] 매칭된 자습 블록: studentId=${b.studentId}, dayIndex=${b.dayIndex}, startTime=${b.startHour}:${b.startMinute}');
                                    }
                                    return matches;
                                  }).cast<SelfStudyTimeBlock>().toList();
                                  // print('[DEBUG][자습블록필터링] 필터링된 자습 블록: ${cellSelfStudyBlocks.length}개');
                                  final cellSelfStudyStudents = cellSelfStudyBlocks.map((b) =>
                                    students.firstWhere(
                                      (s) => s.student.id == b.studentId,
                                      orElse: () => StudentWithInfo(
                                        student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
                                        basicInfo: StudentBasicInfo(studentId: ''),
                                      ),
                                    )
                                  ).where((s) => s.student.id.isNotEmpty).toList(); // 빈 학생 제거
                                  // print('[DEBUG][학생카드리스트] 자습 학생 수: ${cellSelfStudyStudents.length}');
                                  
                                  // 컨테이너는 항상 렌더링(내용은 조건부)
                                  return LayoutBuilder(
                                    builder: (context, constraints) {
                                      final double containerHeight = (constraints.maxHeight - 24).clamp(120.0, double.infinity);
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            margin: const EdgeInsets.only(top: 24), // 등록 버튼과 간격 24
                                            height: containerHeight,
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF18181A),
                                              borderRadius: BorderRadius.circular(18),
                                            ),
                                            alignment: Alignment.topLeft,
                                            child: SingleChildScrollView(
                                              child: (cellStudents.isNotEmpty)
                                                ? _buildStudentCardList(
                                                    cellStudents,
                                                    dayTimeLabel: _getDayTimeString(widget.selectedCellDayIndex, widget.selectedCellStartTime),
                                                  )
                                                : Padding(
                                                    padding: EdgeInsets.all(4.0),
                                                    child: Text(widget.placeholderText ?? '셀을 선택하세요.', style: const TextStyle(color: Colors.white38, fontSize: 16)),
                                                  ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                              },
                              );
                                    },
                                  )
                                // 2) 요일만 선택 시: 해당 요일 등원 시간 그룹 순서대로
                                : (widget.selectedCellDayIndex != null && widget.selectedDayDate != null)
                                  ? ValueListenableBuilder<List<StudentTimeBlock>>(
                                      valueListenable: DataManager.instance.studentTimeBlocksNotifier,
                                      builder: (context, studentTimeBlocks, _) {
                                        final int dayIdx = widget.selectedCellDayIndex!; // 0=월
                                        final DateTime dayDate = widget.selectedDayDate!;
                                        // 해당 요일의 수업 블록에 속한 학생들 모으기 (number==1 우선)
                                        final blocksOfDay = studentTimeBlocks.where((b) => b.dayIndex == dayIdx && (b.number == null || b.number == 1)).toList();
                                        // 셀렉터: 필터가 있으면 필터 학생만
                                        final allStudents = widget.filteredStudentIds == null 
                                          ? DataManager.instance.students
                                          : DataManager.instance.students.where((s) => widget.filteredStudentIds!.contains(s.student.id)).toList();
                                        final Set<String> allowedIds = allStudents.map((s) => s.student.id).toSet();
                                        // 그룹핑: key = 시간표상 수업 시작시간(HH:mm)
                                        final Map<String, List<StudentWithInfo>> groups = {};
                                        for (final b in blocksOfDay) {
                                          if (!allowedIds.contains(b.studentId)) continue;
                                          final student = allStudents.firstWhere((s) => s.student.id == b.studentId, orElse: () => StudentWithInfo(student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary), basicInfo: StudentBasicInfo(studentId: '')));
                                          if (student.student.id.isEmpty) continue;
                                          final key = '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}';
                                          groups.putIfAbsent(key, () => []);
                                          if (!groups[key]!.any((s) => s.student.id == student.student.id)) {
                                            groups[key]!.add(student);
                                          }
                                        }
                                        // 키 정렬: HH:mm 오름차순
                                        int toMinutes(String hhmm) {
                                          final parts = hhmm.split(':');
                                          final h = int.tryParse(parts[0]) ?? 0;
                                          final m = int.tryParse(parts[1]) ?? 0;
                                          return h * 60 + m;
                                        }
                                        final sortedKeys = groups.keys.toList()
                                          ..sort((a, b) => toMinutes(a).compareTo(toMinutes(b)));
                                        return LayoutBuilder(
                                          builder: (context, constraints) {
                                            final double containerHeight = (constraints.maxHeight - 24).clamp(120.0, double.infinity);
                                            return Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  margin: const EdgeInsets.only(top: 24),
                                                  height: containerHeight,
                                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF18181A),
                                                    borderRadius: BorderRadius.circular(18),
                                                  ),
                                                  alignment: Alignment.topLeft,
                                                  child: SingleChildScrollView(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        // 상단 라벨: 요일명 + 날짜 (사이즈 업)
                                                        Padding(
                                                          padding: const EdgeInsets.only(bottom: 8.0, left: 4.0),
                                                          child: Text(
                                                            '${_weekdayLabel(dayIdx)} ${dayDate.month}/${dayDate.day}',
                                                            style: const TextStyle(color: Colors.white70, fontSize: 22, fontWeight: FontWeight.w600),
                                                          ),
                                                        ),
                                                        ...sortedKeys.map((k) {
                                                          final list = groups[k]!;
                                                          list.sort((a, b) => a.student.name.compareTo(b.student.name));
                                                          // 파싱하여 시작시간 전달
                                                          final parts = k.split(':');
                                                          final int hour = int.tryParse(parts[0]) ?? 0;
                                                          final int minute = int.tryParse(parts[1]) ?? 0;
                                                          return Padding(
                                                            padding: const EdgeInsets.only(bottom: 16.0),
                                                            child: Column(
                                                              crossAxisAlignment: CrossAxisAlignment.start,
                                                              children: [
                                                                Padding(
                                                                  padding: const EdgeInsets.only(left: 8.0, bottom: 6.0),
                                                                  child: Text(
                                                                    k, // 시간표상 시작 시간만 표시 (사이즈 업)
                                                                    style: const TextStyle(color: Colors.white70, fontSize: 16.5, fontWeight: FontWeight.w700),
                                                                  ),
                                                                ),
                                                                Wrap(
                                                                  spacing: 6.4,
                                                                  runSpacing: 6.4,
                                                                  children: list.map((info) => _buildDraggableStudentCard(
                                                                    info,
                                                                    dayIndex: dayIdx,
                                                                    startTime: DateTime(dayDate.year, dayDate.month, dayDate.day, hour, minute),
                                                                  )).toList(),
                                                                ),
                                                              ],
                                                            ),
                                                          );
                                                        }),
                                                        if (sortedKeys.isEmpty)
                                                          Padding(
                                                            padding: const EdgeInsets.all(4.0),
                                                            child: Text(widget.placeholderText ?? '해당 요일에 등록된 학생이 없습니다.', style: const TextStyle(color: Colors.white38, fontSize: 16)),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        );
                                      },
                                    )
                                  : LayoutBuilder(
                                    builder: (context, constraints) {
                            final double containerHeight = (constraints.maxHeight - 24).clamp(120.0, double.infinity);
                            return Container(
                              margin: const EdgeInsets.only(top: 24),
                              height: containerHeight,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF18181A),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              alignment: Alignment.center,
                              child: Text(widget.placeholderText ?? '셀을 선택하세요.', style: const TextStyle(color: Colors.white38, fontSize: 17)),
                            );
                                    },
                                  )
                            ),
                      ),
                  // 삭제 드롭존
                  if (_showDeleteZone)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: DragTarget<Map<String, dynamic>>(
                        onWillAccept: (data) => true,
                        onAccept: (data) async {
                          final students = (data['students'] as List)
                              .map((e) => e is StudentWithInfo ? e : e['student'] as StudentWithInfo)
                              .toList();
                          final oldDayIndex = data['oldDayIndex'] as int?;
                          final oldStartTime = data['oldStartTime'] as DateTime?;
                          final isSelfStudy = data['isSelfStudy'] as bool? ?? false;
                          // print('[삭제드롭존] onAccept 호출: students=${students.map((s) => s.student.id).toList()}, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime, isSelfStudy=$isSelfStudy');
                          List<Future> futures = [];
                          
                          if (isSelfStudy) {
                            // 자습 블록 삭제 로직
                            for (final student in students) {
                              // print('[삭제드롭존][자습] studentId=${student.student.id}');
                              // 1. 해당 학생+요일+시간 블록 1개 찾기 (setId 추출용)
                              final targetBlock = DataManager.instance.selfStudyTimeBlocks.firstWhere(
                                (b) =>
                                  b.studentId == student.student.id &&
                                  b.dayIndex == oldDayIndex &&
                                  b.startHour == oldStartTime?.hour &&
                                  b.startMinute == oldStartTime?.minute,
                                orElse: () => SelfStudyTimeBlock(
                                  id: '',
                                  studentId: '',
                                  dayIndex: -1,
                                  startHour: 0,
                                  startMinute: 0,
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
                                  // print('[삭제드롭존][자습] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}');
                                  futures.add(DataManager.instance.removeSelfStudyTimeBlock(b.id));
                                }
                              }
                              // setId가 없는 경우 단일 블록 삭제
                              final blocks = DataManager.instance.selfStudyTimeBlocks.where((b) =>
                                b.studentId == student.student.id &&
                                b.dayIndex == oldDayIndex &&
                                b.startHour == oldStartTime?.hour &&
                                b.startMinute == oldStartTime?.minute
                              ).toList();
                              for (final block in blocks) {
                                // print('[삭제드롭존][자습] 삭제 시도: block.id=${block.id}, block.dayIndex=${block.dayIndex}, block.startTime=${block.startHour}:${block.startMinute}');
                                futures.add(DataManager.instance.removeSelfStudyTimeBlock(block.id));
                              }
                            }
                          } else {
                            // 기존 수업 블록 삭제 로직
                            for (final student in students) {
                              // print('[삭제드롭존][수업] studentId=${student.student.id}');
                              // print('[삭제드롭존][수업] 전체 studentTimeBlocks setId 목록: ' + DataManager.instance.studentTimeBlocks.map((b) => b.setId).toList().toString());
                              // 1. 해당 학생+요일+시간 블록 1개 찾기 (setId 추출용)
                              final targetBlock = DataManager.instance.studentTimeBlocks.firstWhere(
                                (b) =>
                                  b.studentId == student.student.id &&
                                  b.dayIndex == oldDayIndex &&
                                  b.startHour == oldStartTime?.hour &&
                                  b.startMinute == oldStartTime?.minute,
                                orElse: () => StudentTimeBlock(
                                  id: '',
                                  studentId: '',
                                  dayIndex: -1,
                                  startHour: 0,
                                  startMinute: 0,
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
                                  // print('[삭제드롭존][수업] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}');
                                  futures.add(DataManager.instance.removeStudentTimeBlock(b.id));
                                }
                              }
                              // setId가 없는 경우 단일 블록 삭제
                              final blocks = DataManager.instance.studentTimeBlocks.where((b) =>
                                b.studentId == student.student.id &&
                                b.dayIndex == oldDayIndex &&
                                b.startHour == oldStartTime?.hour &&
                                b.startMinute == oldStartTime?.minute
                              ).toList();
                              for (final block in blocks) {
                                // print('[삭제드롭존][수업] 삭제 시도: block.id=${block.id}, block.dayIndex=${block.dayIndex}, block.startTime=${block.startHour}:${block.startMinute}');
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
                          // print('[삭제드롭존] 삭제 후 studentTimeBlocks 개수: ${DataManager.instance.studentTimeBlocks.length}');
                          // print('[삭제드롭존] 삭제 후 selfStudyTimeBlocks 개수: ${DataManager.instance.selfStudyTimeBlocks.length}');
                          // 수업 블록 삭제 후 weekly_class_count를 현재 set 개수로 동기화 (수업 삭제에만 적용)
                          if (!isSelfStudy) {
                            for (final s in students) {
                              final sid = s.student.id;
                              final registered = DataManager.instance.getStudentLessonSetCount(sid);
                              await DataManager.instance.setStudentWeeklyClassCount(sid, registered);
                            }
                          }
                          // 스낵바 즉시 표시 (지연 제거)
                          if (mounted) {
                            final blockType = isSelfStudy ? '자습시간' : '수업시간';
                            showAppSnackBar(context, '${students.length}명 학생의 $blockType이 삭제되었습니다.', useRoot: true);
                          }
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
                              if (MediaQuery.of(context).size.width > 1600) ...[
                                SizedBox(width: 6),
                                Text('수업', style: TextStyle(color: Colors.white70, fontSize: 25, fontWeight: FontWeight.bold)),
                              ],
                              SizedBox(width: 8),
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
                      ],
                    ),
                    const SizedBox(height: 8),
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
            ],
          ),
        ),
        const SizedBox(width: 24),
      ],
    );
  }

  // --- 학생카드 Draggable 래퍼 공통 함수 ---
  Widget _buildDraggableStudentCard(StudentWithInfo info, {int? dayIndex, DateTime? startTime, List<StudentWithInfo>? cellStudents, bool isSelfStudy = false}) {
    // print('[DEBUG][_buildDraggableStudentCard] 호출: student=${info.student.name}, isSelfStudy=$isSelfStudy, dayIndex=$dayIndex, startTime=$startTime');
    // 학생의 고유성을 보장하는 key 생성 (그룹이 있으면 그룹 id까지 포함)
    final cardKey = ValueKey(
      info.student.id + (info.student.groupInfo?.id ?? ''),
    );
    final isSelected = widget.selectedStudentIds.contains(info.student.id);
    // 선택된 학생 리스트
    final selectedStudents = cellStudents?.where((s) => widget.selectedStudentIds.contains(s.student.id)).toList() ?? [];
    final selectedCount = selectedStudents.length;
    // 해당 학생+시간의 StudentTimeBlock에서 setId 추출
    String? setId;
    if (dayIndex != null && startTime != null) {
      final block = DataManager.instance.studentTimeBlocks.firstWhere(
        (b) => b.studentId == info.student.id && b.dayIndex == dayIndex && b.startHour == startTime.hour && b.startMinute == startTime.minute,
        orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
      );
      setId = block.id.isEmpty ? null : block.setId;
    }
    // 다중 선택 시 각 학생의 setId도 포함해서 넘김
    final studentsWithSetId = (isSelected && selectedCount > 1)
        ? selectedStudents.map((s) {
            String? sSetId;
            if (dayIndex != null && startTime != null) {
              final block = DataManager.instance.studentTimeBlocks.firstWhere(
                (b) => b.studentId == s.student.id && b.dayIndex == dayIndex && b.startHour == startTime.hour && b.startMinute == startTime.minute,
                orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
              );
              sSetId = block.id.isEmpty ? null : block.setId;
            }
            return {'student': s, 'setId': sSetId};
          }).toList()
        : [ {'student': info, 'setId': setId} ];
    return Stack(
      children: [
        Builder(builder: (context) {
          final dragData = {
            'type': isClassRegisterMode ? 'register' : 'move',
            'students': studentsWithSetId,
            'student': info,
            'setId': setId,
            'oldDayIndex': dayIndex,
            'oldStartTime': startTime,
            'dayIndex': dayIndex,
            'startTime': startTime,
            'isSelfStudy': isSelfStudy,
          };
          // print('[DEBUG][TT] Draggable dragData 준비: type=${dragData['type']}, setId=${dragData['setId']}, oldDayIndex=${dragData['oldDayIndex']}, oldStartTime=${dragData['oldStartTime']}, studentsCount=${(dragData['students'] as List).length});
          return GestureDetector(
            onLongPressStart: (_) { /* debug off */ },
            onLongPressEnd: (_) { /* debug off */ },
            behavior: HitTestBehavior.translucent,
            child: Listener(
              onPointerDown: (_) {},
              onPointerUp: (_) {},
              onPointerCancel: (_) {},
              child: LongPressDraggable<Map<String, dynamic>>(
                data: dragData,
                onDragStarted: () {
                  setState(() {
                    _showDeleteZone = true;
                  });
                },
                onDragEnd: (details) {
                  setState(() {
                    _showDeleteZone = false;
                  });
                  if (!details.wasAccepted) {
                    if (widget.onExitSelectMode != null) {
                      widget.onExitSelectMode!();
                    }
                  } else {
                    if (widget.onExitSelectMode != null) {
                      widget.onExitSelectMode!();
                    }
                  }
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
                    enableLongPressDrag: false,
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
                  enableLongPressDrag: false,
                ),
              ),
            ),
          );
        }),
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
      // 4개 이상: 카드 쌓임 + 개수 표시(중앙, 원형, 투명 배경, 흰색 아웃라인)
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
              // 숫자 원형 배지
              Positioned(
                left: 48.0 + 25, // 카드 오른쪽에 겹치게
                top: 8,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.transparent, width: 2.2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '+$count',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
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
            (b) => b.studentId == s.student.id && b.dayIndex == selectedDayIdx && b.startHour == selectedStartTime?.hour && b.startMinute == selectedStartTime?.minute,
            orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
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
            padding: const EdgeInsets.only(top: 8.0, bottom: 8.0, left: 8.0),
            child: Text(
              dayTimeLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 20),
            ),
          ),
        if (noSession.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Wrap(
              spacing: 0,
              runSpacing: 6.4,
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
                    child: Builder(builder: (context) {
                      final c = classCards.firstWhere(
                        (c) => c.id == sessionId,
                        orElse: () => ClassInfo(id: '', name: '', color: null, description: '', capacity: null),
                      );
                      final String name = c.id.isEmpty ? '수업' : c.name;
                      final Color color = c.color ?? Colors.white70;
                      return Text(
                        name,
                        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 17),
                      );
                    }),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6.4,
                    runSpacing: 6.4,
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
        final key = '${block.dayIndex}-${block.startHour}:${block.startMinute.toString().padLeft(2, '0')}';
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
          // 검색 결과는 모두 같은 student_id만 포함하므로 첫 학생 기준으로 수업명 추출
          String className = '';
          if (students.isNotEmpty) {
            final studentId = students.first.student.id;
            final block = blocks.firstWhere(
              (b) => b.studentId == studentId && b.dayIndex == dayIdx && b.startHour == hour && b.startMinute == min,
              orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
            );
            if (block.id.isNotEmpty && block.sessionTypeId != null && block.sessionTypeId!.isNotEmpty) {
              final classInfo = DataManager.instance.classes.firstWhere(
                (c) => c.id == block.sessionTypeId,
                orElse: () => ClassInfo(id: '', name: '', color: null, description: '', capacity: null),
              );
              className = classInfo.id.isEmpty ? '' : classInfo.name;
            }
          }
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 학생카드
                      Wrap(
                        spacing: 0,
                        runSpacing: 4,
                        children: students.map((info) =>
                          Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: _buildDraggableStudentCard(info, dayIndex: dayIdx, startTime: DateTime(0, 1, 1, hour, min)),
                          )
                        ).toList(),
                      ),
                      // 수업명: 학생카드 끝~Row 끝까지의 영역에서 가로 가운데 정렬
                      if (className.isNotEmpty)
                        Expanded(
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              className,
                              style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                    ],
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
    print('[DEBUG][clearSessionTypeIdForClass] 시작: classId=$classId');
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.sessionTypeId == classId).toList();
    print('[DEBUG][clearSessionTypeIdForClass] 찾은 블록 수: ${blocks.length}');
    
    for (final block in blocks) {
      print('[DEBUG][clearSessionTypeIdForClass] 업데이트 중: blockId=${block.id}, studentId=${block.studentId}');
      // copyWith(sessionTypeId: null)는 기존 값을 유지하므로, 새 객체 생성
          final updated = StudentTimeBlock(
            id: block.id,
            studentId: block.studentId,
            dayIndex: block.dayIndex,
            startHour: block.startHour,
            startMinute: block.startMinute,
            duration: block.duration,
            createdAt: block.createdAt,
            setId: block.setId,
            number: block.number,
            sessionTypeId: null, // 명시적으로 null 설정
          );
      await DataManager.instance.updateStudentTimeBlock(block.id, updated);
    }
    
    // 🔄 업데이트 후 데이터 새로고침
    await DataManager.instance.loadStudentTimeBlocks();
    print('[DEBUG][clearSessionTypeIdForClass] 완료: 데이터 새로고침됨');
  }

  // 🔍 고아 sessionTypeId 진단 함수
  Future<void> _diagnoseOrphanedSessionTypeIds() async {
    print('[DEBUG][진단] === 고아 sessionTypeId 진단 시작 ===');
    
    final allBlocks = DataManager.instance.studentTimeBlocks;
    final existingClassIds = DataManager.instance.classes.map((c) => c.id).toSet();
    
    print('[DEBUG][진단] 전체 블록 수: ${allBlocks.length}');
    print('[DEBUG][진단] 등록된 수업 ID들: $existingClassIds');
    
    // 모든 sessionTypeId 수집
    final allSessionTypeIds = allBlocks
        .where((b) => b.sessionTypeId != null && b.sessionTypeId!.isNotEmpty)
        .map((b) => b.sessionTypeId!)
        .toSet();
    print('[DEBUG][진단] 사용 중인 sessionTypeId들: $allSessionTypeIds');
    
    // 고아 sessionTypeId 찾기
    final orphanedSessionTypeIds = allSessionTypeIds
        .where((id) => !existingClassIds.contains(id))
        .toSet();
    print('[DEBUG][진단] 고아 sessionTypeId들: $orphanedSessionTypeIds');
    
    // 고아 블록들 찾기
    final orphanedBlocks = allBlocks.where((block) {
      return block.sessionTypeId != null && 
             block.sessionTypeId!.isNotEmpty && 
             !existingClassIds.contains(block.sessionTypeId);
    }).toList();
    
    print('[DEBUG][진단] 고아 블록 수: ${orphanedBlocks.length}');
    
    // 고아 블록들을 sessionTypeId별로 그룹화
    final groupedOrphans = <String, List<StudentTimeBlock>>{};
    for (final block in orphanedBlocks) {
      final sessionTypeId = block.sessionTypeId!;
      groupedOrphans.putIfAbsent(sessionTypeId, () => []).add(block);
    }
    
    for (final entry in groupedOrphans.entries) {
      print('[DEBUG][진단] sessionTypeId ${entry.key}: ${entry.value.length}개 블록');
      // 처음 5개만 샘플로 출력
      final samples = entry.value.take(5);
      for (final block in samples) {
        print('[DEBUG][진단]   - blockId: ${block.id}, studentId: ${block.studentId}');
      }
      if (entry.value.length > 5) {
        print('[DEBUG][진단]   - ... 외 ${entry.value.length - 5}개 더');
      }
    }
    
    print('[DEBUG][진단] === 고아 sessionTypeId 진단 완료 ===');
  }

  // 🧹 삭제된 수업의 sessionTypeId를 가진 블록들을 정리하는 유틸리티 함수
  Future<void> cleanupOrphanedSessionTypeIds() async {
    print('[DEBUG][cleanupOrphanedSessionTypeIds] 시작');
    
    final allBlocks = DataManager.instance.studentTimeBlocks;
    final existingClassIds = DataManager.instance.classes.map((c) => c.id).toSet();
    
    // sessionTypeId가 있지만 해당 수업이 존재하지 않는 블록들 찾기
    final orphanedBlocks = allBlocks.where((block) {
      return block.sessionTypeId != null && 
             block.sessionTypeId!.isNotEmpty && 
             !existingClassIds.contains(block.sessionTypeId);
    }).toList();
    
    print('[DEBUG][cleanupOrphanedSessionTypeIds] 정리할 블록 수: ${orphanedBlocks.length}');
    
    if (orphanedBlocks.isNotEmpty) {
      print('[DEBUG][cleanupOrphanedSessionTypeIds] 고아 sessionTypeId들: ${orphanedBlocks.map((b) => b.sessionTypeId).toSet()}');
      
      try {
        // 🔄 삭제 후 재추가 방식으로 안전하게 처리
        final blockIdsToDelete = orphanedBlocks.map((b) => b.id).toList();
        final updatedBlocks = orphanedBlocks.map<StudentTimeBlock>((block) {
          // copyWith(sessionTypeId: null)는 기존 값을 유지하므로, 새 객체 생성
          return StudentTimeBlock(
            id: block.id,
            studentId: block.studentId,
            dayIndex: block.dayIndex,
            startHour: block.startHour,
            startMinute: block.startMinute,
            duration: block.duration,
            createdAt: block.createdAt,
            setId: block.setId,
            number: block.number,
            sessionTypeId: null, // 명시적으로 null 설정
          );
        }).toList();
        
        print('[DEBUG][cleanupOrphanedSessionTypeIds] 삭제할 블록 ID들: ${blockIdsToDelete.take(5)}${blockIdsToDelete.length > 5 ? '... 외 ${blockIdsToDelete.length - 5}개' : ''}');
        
        // 1. 기존 블록들 삭제
                           await DataManager.instance.bulkDeleteStudentTimeBlocks(blockIdsToDelete);
        print('[DEBUG][cleanupOrphanedSessionTypeIds] 삭제 완료');
        
        // 2. sessionTypeId가 null로 설정된 새 블록들 추가
        print('[DEBUG][cleanupOrphanedSessionTypeIds] 재추가할 블록들의 sessionTypeId: ${updatedBlocks.take(3).map((b) => b.sessionTypeId)}');
                           await DataManager.instance.bulkAddStudentTimeBlocks(updatedBlocks);
        print('[DEBUG][cleanupOrphanedSessionTypeIds] 재추가 완료');
        
        print('[DEBUG][cleanupOrphanedSessionTypeIds] 완료: ${orphanedBlocks.length}개 블록 정리됨 (삭제 후 재추가)');
      } catch (e, stackTrace) {
        print('[ERROR][cleanupOrphanedSessionTypeIds] 정리 중 오류 발생: $e');
        print('[ERROR][cleanupOrphanedSessionTypeIds] 스택트레이스: $stackTrace');
      }
    } else {
      print('[DEBUG][cleanupOrphanedSessionTypeIds] 완료: 정리할 블록 없음');
    }
  }

  // ===== 보강(Replace) 원본 블라인드 맵 =====
  // key: weekNumber|weeklyOrder|sessionTypeId|dayIndex|startMinuteRounded
  Set<String> _makeupOriginalBlindKeysFor(String studentId) {
    final keys = <String>{};
    // DEBUG (quiet)
    // print('[BLIND][map] building keys for student=$studentId');
    // 학생 등록일로 주차 계산
    final registrationDate = () {
      try {
        return DataManager.instance.students.firstWhere((s) => s.student.id == studentId).basicInfo.registrationDate;
      } catch (_) {
        return null;
      }
    }();
    if (registrationDate == null) return keys;

    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;

    int computeWeekNumber(DateTime d) {
      DateTime toMonday(DateTime x) {
        final offset = x.weekday - DateTime.monday;
        return DateTime(x.year, x.month, x.day).subtract(Duration(days: offset));
      }
      final regMon = toMonday(registrationDate);
      final sesMon = toMonday(d);
      final diff = sesMon.difference(regMon).inDays;
      final weeks = diff >= 0 ? (diff ~/ 7) : 0;
      return weeks + 1;
    }

    // 학생의 timeBlocks (weeklyOrder 추정용)
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();

    int? weeklyOrderFor(DateTime original, String? setId) {
      if (setId != null) {
        try {
          return blocks.firstWhere((b) => b.setId == setId).weeklyOrder;
        } catch (_) {}
      }
      // 시간 근접 set 추정 (±30분)
      final dayIdx = (original.weekday - 1).clamp(0, 6);
      final origMin = original.hour * 60 + original.minute;
      int bestDiff = 1 << 30;
      int? bestOrder;
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final start = b.startHour * 60 + b.startMinute;
        final diff = (start - origMin).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestOrder = b.weeklyOrder;
        }
      }
      return bestOrder;
    }

    String keyOf({required int week, required int? order, required String? sessionTypeId, required int dayIdx, required int startMin}) {
      final rounded = (startMin / 5).round() * 5; // 5분 단위 라운딩으로 근접 허용
      return '$week|${order ?? -1}|${sessionTypeId ?? 'null'}|$dayIdx|$rounded';
    }

    final overrides = DataManager.instance.getSessionOverridesForStudent(studentId);
    for (final ov in overrides) {
      if (ov.status == OverrideStatus.canceled) continue;
      if (ov.overrideType != OverrideType.replace) continue;
      final orig = ov.originalClassDateTime;
      if (orig == null) continue;
      final week = computeWeekNumber(orig);
      final order = weeklyOrderFor(orig, ov.setId);
      final dayIdx = (orig.weekday - 1).clamp(0, 6);
      final startMin = orig.hour * 60 + orig.minute;
      final sessionTypeId = ov.sessionTypeId; // 없을 수 있음
      keys.add(keyOf(week: week, order: order, sessionTypeId: sessionTypeId, dayIdx: dayIdx, startMin: startMin));
      // print('[BLIND][map] add key week=$week order=$order set=${ov.setId} stId=${sessionTypeId} day=$dayIdx start=$startMin orig=$orig');
    }
    // print('[BLIND][map] total keys=${keys.length}');
    return keys;
  }

  bool _shouldBlindBlock({required String studentId, required int weekNumber, required int? weeklyOrder, required String? sessionTypeId, required int dayIdx, required int startMin}) {
    final keys = _makeupOriginalBlindKeysFor(studentId);
    final rounded = (startMin / 5).round() * 5;
    final key = '$weekNumber|${weeklyOrder ?? -1}|${sessionTypeId ?? 'null'}|$dayIdx|$rounded';
    final hit = keys.contains(key);
    // print('[BLIND][check] week=$weekNumber order=$weeklyOrder stId=$sessionTypeId day=$dayIdx start=$startMin -> rounded=$rounded hit=$hit');
    return hit;
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
    _nameController = ImeAwareTextEditingController(text: widget.editTarget?.name ?? '');
    _descController = ImeAwareTextEditingController(text: widget.editTarget?.description ?? '');
    _capacityController = ImeAwareTextEditingController(text: widget.editTarget?.capacity?.toString() ?? '');
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
      id: widget.editTarget?.id ?? const Uuid().v4(),
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

  Future<void> _handleStudentDrop(Map<String, dynamic> data) async {
    // 다중이동: students 리스트가 있으면 병렬 처리
    final students = data['students'] as List<dynamic>?;
    if (students != null && students.isNotEmpty) {
      // print('[DEBUG][_handleStudentDrop] 다중 등록 시도: [36m${students.map((e) => (e['student'] as StudentWithInfo).student.id + '|' + (e['setId'] ?? 'null')).toList()}[0m');
      await Future.wait(students.map((entry) {
        final studentWithInfo = entry['student'] as StudentWithInfo?;
        final setId = entry['setId'] as String?;
        // print('[DEBUG][_handleStudentDrop] 처리: studentId=${studentWithInfo?.student.id}, setId=$setId');
        return studentWithInfo != null ? _registerSingleStudent(studentWithInfo, setId: setId) : Future.value();
      }));
      // await DataManager.instance.loadStudentTimeBlocks(); // 전체 reload 제거
      // print('[DEBUG][_handleStudentDrop] 다중 등록 완료(병렬): ${students.map((e) => (e['student'] as StudentWithInfo).student.name + '|' + (e['setId'] ?? 'null')).toList()}');
      return;
    }
    // 기존 단일 등록 로직 (아래 함수로 분리)
    final studentWithInfo = data['student'] as StudentWithInfo?;
    final setId = data['setId'] as String?;
    if (studentWithInfo == null || setId == null) {
      // print('[DEBUG][_handleStudentDrop] 드래그 데이터 부족: studentWithInfo= [33m$studentWithInfo [0m, setId=$setId');
      return;
    }
    await _registerSingleStudent(studentWithInfo, setId: setId);
    // await DataManager.instance.loadStudentTimeBlocks(); // 전체 reload 제거
    // print('[DEBUG][_handleStudentDrop] 단일 등록 완료: ${studentWithInfo.student.name}');
  }

  // 단일 학생 등록 로직 분리
  Future<void> _registerSingleStudent(StudentWithInfo studentWithInfo, {String? setId}) async {
    // print('[DEBUG][_registerSingleStudent] 호출: studentId=${studentWithInfo.student.id}, setId=$setId');
    setId ??= DataManager.instance.studentTimeBlocks.firstWhere(
      (b) => b.studentId == studentWithInfo.student.id,
      orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
    ).setId;
    if (setId == null) {
      // print('[DEBUG][_registerSingleStudent] setId가 null, 등록 스킵');
      return;
    }
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentWithInfo.student.id && b.setId == setId)
        .toList();
    // print('[DEBUG][_registerSingleStudent] setId=$setId, studentId=${studentWithInfo.student.id}, 변경 대상 블록 개수=${blocks.length}');
    for (final block in blocks) {
      final updated = block.copyWith(sessionTypeId: widget.classInfo.id);
      // print('[DEBUG][_registerSingleStudent] update block: id=${block.id}, setId=${block.setId}, dayIndex=${block.dayIndex}, startTime=${block.startHour}:${block.startMinute}, sessionTypeId=${widget.classInfo.id}');
      await DataManager.instance.updateStudentTimeBlock(block.id, updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.classInfo;
    final int studentCount = DataManager.instance.getStudentCountForClass(widget.classInfo.id);
    // print('[DEBUG][_ClassCard.build] 전체 studentTimeBlocks=' + DataManager.instance.studentTimeBlocks.map((b) => '${b.studentId}:${b.sessionTypeId}').toList().toString());
    return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        print('[DEBUG][_ClassCard.onWillAccept] data=$data');
        // print('[DEBUG][DragTarget] onWillAccept: data= [33m$data [0m');
        if (data == null) return false;
        final isMulti = data['students'] is List;
        if (isMulti) {
          final entries = (data['students'] as List).cast<Map<String, dynamic>>();
          // print('[DEBUG][onWillAccept] entries=$entries');
          for (final entry in entries) {
            final student = entry['student'] as StudentWithInfo?;
            final setId = entry['setId'] as String?;
            if (student == null || setId == null) return false;
            final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.sessionTypeId == widget.classInfo.id).toList();
            final alreadyRegistered = blocks.any((b) => b.studentId == student.student.id && b.setId == setId);
            // print('[DEBUG][onWillAccept] alreadyRegistered=$alreadyRegistered for studentId=${student?.student.id}, setId=$setId');
            if (alreadyRegistered) return false;
          }
          return true;
        } else {
          final student = data['student'] as StudentWithInfo?;
          final setId = data['setId'] as String?;
          if (student == null || setId == null) return false;
          final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.sessionTypeId == widget.classInfo.id).toList();
          final alreadyRegistered = blocks.any((b) => b.studentId == student.student.id && b.setId == setId);
          // print('[DEBUG][onWillAccept] (단일) studentId=${student.student.id}, setId=$setId, alreadyRegistered=$alreadyRegistered');
          if (alreadyRegistered) return false;
          return true;
        }
      },
      onAccept: (data) async {
        // print('[DEBUG][DragTarget] onAccept: data= [32m$data [0m');
        setState(() => _isHovering = false);
        await _handleStudentDrop(data);
      },
      onMove: (_) {
        // print('[DEBUG][DragTarget] onMove');
        setState(() => _isHovering = true);
      },
      onLeave: (_) {
        // print('[DEBUG][DragTarget] onLeave');
        setState(() => _isHovering = false);
      },
      builder: (context, candidateData, rejectedData) {
        // print('[DEBUG][DragTarget] builder: candidateData=$candidateData, rejectedData=$rejectedData, _isHovering=$_isHovering');
        return Card(
          key: widget.key,
          color: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: _isHovering
              ? BorderSide(color: c.color ?? const Color(0xFFB0B0B0), width: 2.5)
              : const BorderSide(color: Color(0xFF3A3A3A), width: 2.0),
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
                        border: Border.all(color: Color(0xFF18181A), width: 1.4), // 카드 배경색과 동일하게
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

