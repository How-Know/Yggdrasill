import 'package:flutter/material.dart';
import '../../../models/class_info.dart';
import '../../../models/student.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../timetable_screen.dart';  // TimetableViewType enum을 가져오기 위한 import

class TimetableHeader extends StatelessWidget {
  final Function(DateTime) onDateChanged;
  final DateTime selectedDate;

  const TimetableHeader({
    Key? key,
    required this.onDateChanged,
    required this.selectedDate,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            onDateChanged(
              selectedDate.subtract(const Duration(days: 1)),
            );
          },
        ),
        Text(
          '${selectedDate.year}년 ${selectedDate.month}월 ${selectedDate.day}일',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            onDateChanged(
              selectedDate.add(const Duration(days: 1)),
            );
          },
        ),
      ],
    );
  }
} 