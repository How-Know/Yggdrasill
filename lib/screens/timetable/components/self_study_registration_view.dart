import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/class_schedule.dart';
import '../../../models/operating_hours.dart';
import '../../../services/data_manager.dart';

class SelfStudyRegistrationView extends StatefulWidget {
  final StudentWithInfo selectedStudent;
  final List<OperatingHours> operatingHours;
  final int? selectedDayIndex;
  final void Function(int dayIdx, DateTime startTime) onRegisterComplete;

  const SelfStudyRegistrationView({
    Key? key,
    required this.selectedStudent,
    required this.operatingHours,
    required this.selectedDayIndex,
    required this.onRegisterComplete,
  }) : super(key: key);

  @override
  State<SelfStudyRegistrationView> createState() => _SelfStudyRegistrationViewState();
}

class _SelfStudyRegistrationViewState extends State<SelfStudyRegistrationView> {
  int? _hoveredDayIdx;
  DateTime? _hoveredStartTime;

  void _onCellDragAccept(int dayIdx, DateTime startTime) async {
    // 자습 블록 생성 로직 (DB 저장은 timetable_screen.dart에서 처리)
    widget.onRegisterComplete(dayIdx, startTime);
  }

  @override
  Widget build(BuildContext context) {
    // operatingHours, timetable 셀 UI 등은 ClassesView와 유사하게 구현
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.operatingHours.length,
              childAspectRatio: 2.5,
            ),
            itemCount: widget.operatingHours.length * 12, // 예시: 12타임블록
            itemBuilder: (context, idx) {
              final dayIdx = idx % widget.operatingHours.length;
              final opHour = widget.operatingHours[dayIdx];
              // 예시: 각 요일의 시작시간 기준으로 12블록 생성 (실제 로직은 운영시간에 맞게 조정 필요)
              final blockIdx = idx ~/ widget.operatingHours.length;
              final hour = opHour.startHour + blockIdx; // OperatingHours.startHour 기준
              final startTime = DateTime(0, 1, 1, hour, 0);
              return DragTarget(
                onWillAccept: (data) => true,
                onAccept: (data) => _onCellDragAccept(dayIdx, startTime),
                builder: (context, candidateData, rejectedData) {
                  return Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: (_hoveredDayIdx == dayIdx && _hoveredStartTime == startTime)
                          ? Colors.blue.withOpacity(0.2)
                          : Colors.transparent,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Center(
                      child: Text('${hour}:00', style: const TextStyle(color: Colors.white70)),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text('학생: ${widget.selectedStudent.student.name}', style: const TextStyle(color: Colors.white)),
      ],
    );
  }
} 