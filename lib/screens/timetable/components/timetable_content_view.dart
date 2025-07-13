import 'package:flutter/material.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/student_card.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../main.dart'; // rootScaffoldMessengerKey import

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
  final void Function(List<StudentWithInfo>)? onCellStudentsChanged;

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
  }) : super(key: key);

  @override
  State<TimetableContentView> createState() => _TimetableContentViewState();
}

class _TimetableContentViewState extends State<TimetableContentView> {
  final GlobalKey _dropdownButtonKey = GlobalKey();
  OverlayEntry? _dropdownOverlay;
  bool _showDeleteZone = false;

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
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
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
                        ],
                      ),
                      // 학생카드 리스트 위에 요일+시간 출력
                      if (widget.selectedCellStudents != null && widget.selectedCellStudents!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 8.0),
                          child: Text(
                            _getDayTimeString(widget.selectedCellDayIndex, widget.selectedCellStartTime),
                            style: const TextStyle(color: Colors.white70, fontSize: 20),
                          ),
                        ),
                      if (widget.selectedCellStudents != null && widget.selectedCellStudents!.isNotEmpty)
                        Expanded(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2.0),
                              child: Wrap(
                                spacing: 0,
                                runSpacing: 4,
                                children: widget.selectedCellStudents!.map((info) =>
                                  Draggable<StudentWithInfo>(
                                    data: info,
                                    onDragStarted: () => setState(() => _showDeleteZone = true),
                                    onDragEnd: (_) => setState(() => _showDeleteZone = false),
                                    feedback: Material(
                                      color: Colors.transparent,
                                      child: Opacity(
                                        opacity: 0.85,
                                        child: StudentCard(
                                          studentWithInfo: info,
                                          onShowDetails: (info) {},
                                        ),
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.3,
                                      child: StudentCard(
                                        studentWithInfo: info,
                                        onShowDetails: (info) {},
                                      ),
                                    ),
                                    child: StudentCard(
                                      studentWithInfo: info,
                                      onShowDetails: (info) {},
                                    ),
                                  )
                                ).toList(),
                              ),
                            ),
                          ),
                        ),
                  // 삭제 드롭존
                  if (_showDeleteZone)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: DragTarget<StudentWithInfo>(
                        onWillAccept: (student) => true,
                        onAccept: (student) async {
                          // 해당 학생의 시간표 블록 삭제
                          final studentId = student.student.id;
                          final dayIdx = widget.selectedCellDayIndex;
                          final startTime = widget.selectedCellStartTime;
                          if (dayIdx != null && startTime != null) {
                            // student_time_block에서 해당 학생+요일+시간 블록 찾기
                            final blocks = DataManager.instance.studentTimeBlocks.where((b) =>
                              b.studentId == studentId &&
                              b.dayIndex == dayIdx &&
                              b.startTime.hour == startTime.hour &&
                              b.startTime.minute == startTime.minute
                            ).toList();
                            for (final block in blocks) {
                              await DataManager.instance.removeStudentTimeBlock(block.id);
                            }
                            // 삭제 후 데이터 즉시 새로고침
                            await DataManager.instance.loadStudents();
                            await DataManager.instance.loadStudentTimeBlocks();
                            setState(() {
                              _showDeleteZone = false;
                              // (필요하다면 다른 상태도 여기서 갱신)
                            });
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
                            // 삭제 후 등록버튼 컨테이너 내 학생카드 리스트도 즉시 반영
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
                                widget.onCellStudentsChanged!(updatedCellStudents);
                              }
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