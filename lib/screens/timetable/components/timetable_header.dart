import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/group_info.dart';
import '../../../models/student.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../timetable_screen.dart';  // TimetableViewType enum을 가져오기 위한 import

class TimetableHeader extends StatelessWidget {
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

  List<DateTime> _getWeekDays() {
    // 현재 선택된 날짜가 있는 주의 월요일을 찾습니다
    final monday = selectedDate.subtract(Duration(days: selectedDate.weekday - 1));
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
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
              child: Text(
                '시간',
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          // 요일 헤더들
          ...List.generate(7, (index) {
            final date = weekDays[index];
            final isSelected = index == selectedDayIndex;
            
            return Expanded(
              child: Tooltip(
                message: _formatDate(date),
                child: InkWell(
                  onTap: () {
                    onDaySelected(index);
                    onDateChanged(date);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected && isRegistrationMode 
                        ? Colors.orange.withOpacity(0.2)
                        : isSelected 
                          ? Colors.blue.withOpacity(0.2) 
                          : null,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Text(
                        _getWeekdayName(date.weekday),
                        style: TextStyle(
                          color: isSelected && isRegistrationMode
                            ? Colors.orange
                            : isSelected
                              ? Colors.blue
                              : Colors.grey.shade400,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
} 