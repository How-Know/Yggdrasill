import 'package:flutter/material.dart';
import '../../../models/operating_hours.dart';

class ClassesView extends StatelessWidget {
  final List<OperatingHours> operatingHours;
  final Color breakTimeColor;

  const ClassesView({
    super.key,
    required this.operatingHours,
    this.breakTimeColor = const Color(0xFF424242),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final timeBlocks = _generateTimeBlocks();
        final double blockHeight = 60.0; // 30분당 30픽셀, 1시간 블록은 60픽셀

        return Column(
          children: [
            for (final block in timeBlocks)
              Container(
                width: constraints.maxWidth,
                height: blockHeight,
                decoration: BoxDecoration(
                  color: block.isBreakTime ? breakTimeColor : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    // Time indicator
                    SizedBox(
                      width: 80,
                      child: Center(
                        child: Text(
                          block.timeString,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    // Time block content
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Colors.white.withOpacity(0.1),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  List<TimeBlock> _generateTimeBlocks() {
    final List<TimeBlock> blocks = [];
    
    for (final hours in operatingHours) {
      var currentTime = hours.startTime;
      
      while (currentTime.isBefore(hours.endTime)) {
        final endTime = currentTime.add(const Duration(minutes: 60));
        final isBreakTime = hours.breakTimes.any((breakTime) =>
          (currentTime.isAfter(breakTime.startTime) || currentTime.isAtSameMomentAs(breakTime.startTime)) &&
          currentTime.isBefore(breakTime.endTime));

        blocks.add(
          TimeBlock(
            startTime: currentTime,
            endTime: endTime,
            isBreakTime: isBreakTime,
          ),
        );
        
        currentTime = endTime;
      }
    }

    return blocks;
  }
}

class TimeBlock {
  final DateTime startTime;
  final DateTime endTime;
  final bool isBreakTime;

  TimeBlock({
    required this.startTime,
    required this.endTime,
    this.isBreakTime = false,
  });

  String get timeString {
    return '${_formatTime(startTime)} - ${_formatTime(endTime)}';
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
} 