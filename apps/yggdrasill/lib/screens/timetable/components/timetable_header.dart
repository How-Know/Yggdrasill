import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
            const Spacer(),
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
                      onTap: () {
                        // 요일 클릭: 상위에서 전달된 콜백 호출 (0=월)
                        widget.onDaySelected(index);
                      },
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
