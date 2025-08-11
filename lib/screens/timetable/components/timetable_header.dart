import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/group_info.dart';
import '../../../models/student.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../timetable_screen.dart';  // TimetableViewType enum을 가져오기 위한 import

class TimetableHeader extends StatefulWidget {
  final Function(DateTime) onDateChanged;
  final DateTime selectedDate;
  final int? selectedDayIndex;
  final Function(int) onDaySelected;
  final bool isRegistrationMode;
  final VoidCallback? onFilterPressed; // 추가
  final bool isFilterActive; // 추가
  final void Function(bool selecting)? onSelectModeChanged;
  final bool isSelectMode; // 추가: 선택모드 상태 명시적으로 전달
  final VoidCallback? onSelectAllStudents; // 추가: 모두 선택 콜백

  const TimetableHeader({
    Key? key,
    required this.onDateChanged,
    required this.selectedDate,
    this.selectedDayIndex,
    required this.onDaySelected,
    this.isRegistrationMode = false,
    this.onFilterPressed, // 추가
    this.isFilterActive = false, // 추가
    this.onSelectModeChanged,
    this.isSelectMode = false, // 추가
    this.onSelectAllStudents, // 추가
  }) : super(key: key);

  @override
  State<TimetableHeader> createState() => _TimetableHeaderState();
}

class _TimetableHeaderState extends State<TimetableHeader> {
  int _selectedSegment = 0; // 0: 모든, 1: 학년, 2: 학교, 3: 그룹

  List<DateTime> _getWeekDays() {
    final monday = widget.selectedDate.subtract(Duration(days: widget.selectedDate.weekday - 1));
    return List.generate(7, (index) => monday.add(Duration(days: index)));
  }

  int _getWeekOfMonth(DateTime date) {
    // 월 기준 주차 (월요일 시작)
    final firstDayOfMonth = DateTime(date.year, date.month, 1);
    final firstDayWeekday = firstDayOfMonth.weekday; // Mon=1..Sun=7
    final offset = firstDayWeekday - 1; // 월요일=0
    final weekNumber = ((date.day - 1 + offset) / 7).floor() + 1;
    return weekNumber;
  }

  DateTime _getWeekStart(DateTime date) {
    final monday = date.subtract(Duration(days: date.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  DateTime _getWeekEnd(DateTime date) {
    final start = _getWeekStart(date);
    final end = start.add(const Duration(days: 6));
    return DateTime(end.year, end.month, end.day);
  }

  String _formatWeekRange(DateTime date) {
    final s = _getWeekStart(date);
    final e = _getWeekEnd(date);
    return '${s.month}월 ${s.day}일 ~ ${e.month}월 ${e.day}일';
  }

  String _getWeekdayName(int weekday) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return weekdays[weekday - 1];
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일';
  }

  // (삭제됨) 추가 수업 점 표시는 학생 달력에서만 처리합니다.

  @override
  Widget build(BuildContext context) {
    final weekDays = _getWeekDays();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 0), // 세그먼트 버튼 상단 여백을 0으로 변경
        Row(
          children: [
            Padding(
              padding: EdgeInsets.only(left: 30), // 월 정보 및 주차/이동 컨트롤
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '${widget.selectedDate.month}',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 60,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Tooltip(
                    message: _formatWeekRange(widget.selectedDate),
                    waitDuration: const Duration(milliseconds: 200),
                    child: SizedBox(
                      height: 60, // 월정보 텍스트 높이에 맞춰 수직 중앙 정렬
                      child: Padding(
                        padding: const EdgeInsets.only(top: 5), // 살짝 아래로 내림
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                        IconButton(
                          tooltip: '이전 주',
                          onPressed: () {
                            final newDate = widget.selectedDate.subtract(const Duration(days: 7));
                            widget.onDateChanged(newDate);
                          },
                          icon: const Icon(Icons.chevron_left, color: Colors.white70),
                          splashRadius: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () {
                            // 이번주로 이동 (오늘 날짜 기준)
                            widget.onDateChanged(DateTime.now());
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                            child: Text(
                              '${_getWeekOfMonth(widget.selectedDate)}주차',
                              style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: '다음 주',
                          onPressed: () {
                            final newDate = widget.selectedDate.add(const Duration(days: 7));
                            widget.onDateChanged(newDate);
                          },
                          icon: const Icon(Icons.chevron_right, color: Colors.white70),
                          splashRadius: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center( // Align 대신 Center 사용으로 완전 중앙 고정
                child: SizedBox(
                  width: 220, // 기존 440에서 220으로 축소
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('메인')),
                      ButtonSegment(value: 1, label: Text('특강')),
                    ],
                    selected: {_selectedSegment},
                    onSelectionChanged: (Set<int> newSelection) {
                      setState(() {
                        _selectedSegment = newSelection.first;
                      });
                    },
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.all(Colors.transparent),
                      foregroundColor: MaterialStateProperty.resolveWith<Color>(
                        (Set<MaterialState> states) {
                          if (states.contains(MaterialState.selected)) {
                            return Colors.white;
                          }
                          return Colors.white70;
                        },
                      ),
                      textStyle: MaterialStateProperty.all(
                        const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 오른쪽 영역 고정 크기로 세그먼트 버튼 중앙 정렬 유지
            SizedBox(
              width: 230, // 선택 버튼 + filter 버튼을 위한 고정 크기
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // 선택 버튼 (filter 버튼 왼쪽)
                  _SelectButtonAnimated(
                    onSelectModeChanged: widget.onSelectModeChanged,
                    isSelectMode: widget.isSelectMode,
                    onSelectAllStudents: widget.onSelectAllStudents,
                  ),
                  SizedBox(width: 12),
                  // filter 버튼 (오른쪽 정렬, 세그먼트 버튼 스타일)
                  SizedBox(
                    height: 40,
                    width: 104, // 기존 80~90에서 30% 증가(80*1.3=104)
                    child: OutlinedButton(
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.all(Colors.transparent),
                        shape: MaterialStateProperty.all(RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        )),
                        side: MaterialStateProperty.all(BorderSide(color: Colors.grey.shade600, width: 1.2)),
                        padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 0)),
                        foregroundColor: MaterialStateProperty.all(Colors.white70),
                        textStyle: MaterialStateProperty.all(const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        overlayColor: MaterialStateProperty.all(Colors.white.withOpacity(0.07)),
                      ),
                      onPressed: widget.onFilterPressed,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          const Icon(Icons.filter_alt_outlined, size: 20),
                          const SizedBox(width: 6),
                          const Text('filter'),
                          if (widget.isFilterActive) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.close, size: 18, color: Colors.white70),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20), // 세그먼트 버튼과 요일 row 사이 여백 추가
        // 요일 row는 Row 바깥에 별도 배치
        Container(
          padding: EdgeInsets.symmetric(horizontal: 0), // 좌우 여백을 0으로 변경
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Colors.grey.shade800,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // 시간 열 헤더
              SizedBox(
                width: 60,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '시간',
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 18, // 기존 14에서 18로 증가
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: 15), // 요일과 줄 맞춤
                    ],
                  ),
                ),
              ),
              // 요일 헤더들
              ...List.generate(7, (index) {
                final date = weekDays[index];
                return Expanded(
                  child: Tooltip(
                    message: _formatDate(date),
                    child: InkWell(
                      onTap: null, // 요일 클릭 비활성화
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: const BoxDecoration(), // 하이라이트 없음
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _getWeekdayName(date.weekday),
                                style: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 18, // 기존 16에서 2 증가
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(height: 15), // 요일 글자와 밑줄 사이 여백 복구
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}

// 선택 버튼 애니메이션 위젯
class _SelectButtonAnimated extends StatefulWidget {
  final void Function(bool selecting)? onSelectModeChanged;
  final bool isSelectMode; // 추가: 선택모드 상태 명시적으로 전달
  final VoidCallback? onSelectAllStudents; // 추가: 모두 선택 콜백
  const _SelectButtonAnimated({this.onSelectModeChanged, this.isSelectMode = false, this.onSelectAllStudents});
  @override
  State<_SelectButtonAnimated> createState() => _SelectButtonAnimatedState();
}

class _SelectButtonAnimatedState extends State<_SelectButtonAnimated> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _splitAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _splitAnim = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    if (widget.isSelectMode) {
      _controller.value = 1.0;
    } else {
      _controller.value = 0.0;
    }
  }

  @override
  void didUpdateWidget(covariant _SelectButtonAnimated oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelectMode != oldWidget.isSelectMode) {
      if (widget.isSelectMode) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  void _onSelectPressed() {
    widget.onSelectModeChanged?.call(true);
  }

  void _onCancelPressed() {
    widget.onSelectModeChanged?.call(false);
  }

  void _onSelectAllPressed() {
    // 모두 선택 콜백 호출
    widget.onSelectAllStudents?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttonStyle = ButtonStyle(
      backgroundColor: MaterialStateProperty.all(Colors.transparent),
      shape: MaterialStateProperty.all(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      )),
      side: MaterialStateProperty.all(BorderSide(color: Colors.grey.shade600, width: 1.2)),
      padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 0)),
      foregroundColor: MaterialStateProperty.all(Colors.white70),
      textStyle: MaterialStateProperty.all(const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      overlayColor: MaterialStateProperty.all(Colors.white.withOpacity(0.07)),
    );
    return AnimatedBuilder(
      animation: _splitAnim,
      builder: (context, child) {
        final split = _splitAnim.value;
        if (!widget.isSelectMode && split == 0) {
          // 선택 버튼
          return SizedBox(
            height: 40,
            width: 104,
            child: OutlinedButton(
              style: buttonStyle,
              onPressed: _onSelectPressed,
              child: const Center(
                child: Text('선택'),
              ),
            ),
          );
        } else {
          // 분리된 버튼 (모두, 취소)
          return Row(
            children: [
              SizedBox(
                height: 40,
                width: 60 + 44 * (1 - split), // 애니메이션으로 자연스럽게 넓이 변화
                child: OutlinedButton(
                  style: buttonStyle.copyWith(
                    shape: MaterialStateProperty.all(RoundedRectangleBorder(
                      borderRadius: BorderRadius.horizontal(
                        left: const Radius.circular(24),
                        right: Radius.circular(24 * (1 - split) + 24 * split),
                      ),
                    )),
                  ),
                  onPressed: _onSelectAllPressed,
                  child: const Center(
                    child: Text('모두'),
                  ),
                ),
              ),
              SizedBox(width: 4 * split),
              Opacity(
                opacity: split,
                child: SizedBox(
                  height: 40,
                  width: 44 * split,
                  child: OutlinedButton(
                    style: buttonStyle.copyWith(
                      shape: MaterialStateProperty.all(RoundedRectangleBorder(
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(24 * split),
                          right: const Radius.circular(24),
                        ),
                      )),
                    ),
                    onPressed: _onCancelPressed,
                    child: const Center(
                      child: Icon(Icons.close, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );
  }
} 