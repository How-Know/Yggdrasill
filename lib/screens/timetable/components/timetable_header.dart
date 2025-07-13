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

  const TimetableHeader({
    Key? key,
    required this.onDateChanged,
    required this.selectedDate,
    this.selectedDayIndex,
    required this.onDaySelected,
    this.isRegistrationMode = false,
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

  String _getWeekdayName(int weekday) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return weekdays[weekday - 1];
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일';
  }

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
              padding: EdgeInsets.only(left: 30), // 월 정보만 왼쪽 여백
              child: Text(
                '${widget.selectedDate.month}',
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 60,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: 440, // 세그먼트 버튼 너비
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('모든')),
                      ButtonSegment(value: 1, label: Text('학년')),
                      ButtonSegment(value: 2, label: Text('학교')),
                      ButtonSegment(value: 3, label: Text('그룹')),
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
                              SizedBox(height: 15), // 요일 글자와 밑줄 사이 여백 추가
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