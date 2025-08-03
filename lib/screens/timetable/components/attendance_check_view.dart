import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../models/class_info.dart';
import '../../../models/attendance_record.dart';
import '../../../services/data_manager.dart';

class AttendanceCheckView extends StatefulWidget {
  final StudentWithInfo? selectedStudent;

  const AttendanceCheckView({
    super.key,
    required this.selectedStudent,
  });

  @override
  State<AttendanceCheckView> createState() => _AttendanceCheckViewState();
}

class _AttendanceCheckViewState extends State<AttendanceCheckView> {
  List<ClassSession> _classSessions = [];
  int _centerIndex = 7; // 가운데 수업 인덱스 (0~14 중 7번째)

  @override
  void initState() {
    super.initState();
    _loadClassSessions();
  }

  @override
  void didUpdateWidget(AttendanceCheckView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedStudent != widget.selectedStudent) {
      _loadClassSessions();
    }
  }

  void _loadClassSessions() {
    if (widget.selectedStudent == null) {
      setState(() {
        _classSessions = [];
      });
      return;
    }

    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == widget.selectedStudent!.student.id)
        .toList();

    if (timeBlocks.isEmpty) {
      setState(() {
        _classSessions = [];
      });
      return;
    }

    final now = DateTime.now();
    final sessions = <ClassSession>[];

    // SET_ID별로 timeBlocks 그룹화
    final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
    for (final block in timeBlocks) {
      blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
    }

    // 현재 날짜를 기준으로 ±4주간의 수업 일정 생성
    for (int weekOffset = -4; weekOffset <= 4; weekOffset++) {
      final weekStart = now.add(Duration(days: -now.weekday + 1 + (weekOffset * 7)));
      
      for (final entry in blocksBySetId.entries) {
        final setId = entry.key;
        final blocks = entry.value;
        
        if (blocks.isEmpty) continue;
        
        // 각 SET_ID별로 하나의 카드만 생성 (첫 번째 블록 기준)
        final firstBlock = blocks.first;
        final classDate = weekStart.add(Duration(days: firstBlock.dayIndex));
        final classDateTime = DateTime(
          classDate.year,
          classDate.month,
          classDate.day,
          firstBlock.startHour,
          firstBlock.startMinute,
        );

        // 수업명 가져오기
        String className = '수업';
        try {
          final classInfo = DataManager.instance.classes
              .firstWhere((c) => c.id == firstBlock.sessionTypeId);
          className = classInfo.name;
        } catch (e) {
          // 클래스 정보를 찾지 못한 경우 기본값 사용
        }

        // 기존 출석 기록 확인
        final attendanceRecord = DataManager.instance.getAttendanceRecord(
          widget.selectedStudent!.student.id,
          classDate,
          classDateTime,
        );

        sessions.add(ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekName(firstBlock.dayIndex),
          duration: firstBlock.duration.inMinutes, // Duration을 int(분)로 변환
          isAttended: attendanceRecord?.isPresent ?? false, // 기존 출석 기록 반영
          arrivalTime: attendanceRecord?.arrivalTime,
          departureTime: attendanceRecord?.departureTime,
        ));
      }
    }

    // 날짜순 정렬
    sessions.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    // 오늘 수업이 있는지 확인
    final today = DateTime(now.year, now.month, now.day);
    int centerIndex = -1;
    
    // 먼저 오늘 수업을 찾기
    for (int i = 0; i < sessions.length; i++) {
      final sessionDate = DateTime(sessions[i].dateTime.year, sessions[i].dateTime.month, sessions[i].dateTime.day);
      if (sessionDate.isAtSameMomentAs(today)) {
        centerIndex = i;
        break;
      }
    }
    
    // 오늘 수업이 없으면 오늘에 가장 가까운 이전 수업 찾기
    if (centerIndex == -1) {
      for (int i = sessions.length - 1; i >= 0; i--) {
        final sessionDate = DateTime(sessions[i].dateTime.year, sessions[i].dateTime.month, sessions[i].dateTime.day);
        if (sessionDate.isBefore(today) || sessionDate.isAtSameMomentAs(today)) {
          centerIndex = i;
          break;
        }
      }
    }
    
    // 여전히 찾지 못했으면 (모든 수업이 미래) 첫 번째 수업을 중심으로
    if (centerIndex == -1 && sessions.isNotEmpty) {
      centerIndex = 0;
    }
    
    // 15개 수업만 선택 (가운데 수업 기준으로 앞뒤 7개씩)
    if (sessions.length <= 15) {
      // 전체 수업이 15개 이하면 모두 표시하고 가운데 인덱스 조정
      final actualCenterIndex = centerIndex.clamp(0, sessions.length - 1);
      setState(() {
        _classSessions = sessions;
        _centerIndex = actualCenterIndex;
      });
      return;
    }
    
    // 15개보다 많으면 가운데 기준으로 앞뒤 7개씩 선택
    final startIndex = (centerIndex - 7).clamp(0, sessions.length - 15);
    final endIndex = startIndex + 15;
    final selectedSessions = sessions.sublist(startIndex, endIndex);

    // 실제 가운데 인덱스 계산 (선택된 세션 내에서의 위치)
    final actualCenterIndex = centerIndex - startIndex;

    setState(() {
      _classSessions = selectedSessions;
      _centerIndex = actualCenterIndex.clamp(0, selectedSessions.length - 1);
    });
  }

  String _getDayOfWeekName(int dayIndex) {
    const days = ['일', '월', '화', '수', '목', '금', '토'];
    return days[dayIndex % 7];
  }

  Widget _buildClassSessionCard(ClassSession session, int index, double cardWidth) {
    final isCenter = index == _centerIndex;
    final isPast = session.dateTime.isBefore(DateTime.now());
    
    // 다음 수업(미래 수업 중 가장 가까운 것) 찾기
    final now = DateTime.now();
    final isNextClass = !isPast && _classSessions.where((s) => s.dateTime.isAfter(now)).isNotEmpty && 
        session.dateTime == _classSessions.where((s) => s.dateTime.isAfter(now)).first.dateTime;
    
    // 등원/하원 시간 정보가 있으면 툴팁 메시지 생성
    String tooltipMessage = '';
    if (session.arrivalTime != null || session.departureTime != null) {
      if (session.arrivalTime != null) {
        final arrivalTime = session.arrivalTime!;
        tooltipMessage += '등원: ${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';
      }
      if (session.departureTime != null) {
        final departureTime = session.departureTime!;
        if (tooltipMessage.isNotEmpty) tooltipMessage += '\n';
        tooltipMessage += '하원: ${departureTime.hour.toString().padLeft(2, '0')}:${departureTime.minute.toString().padLeft(2, '0')}';
      }
    }
    
    // 끝시간 계산
    final endTime = session.dateTime.add(Duration(minutes: session.duration));
    
    Widget cardWidget = Container(
      width: cardWidth,
      height: 140, // 카드 높이 추가 증가 (130→140)
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isNextClass 
            ? const Color(0xFF1976D2).withOpacity(0.3)  // 다음 수업은 filled box
            : const Color(0xFF2A2A2A),  // 기본 배경
        borderRadius: BorderRadius.circular(8),
        border: isCenter 
            ? Border.all(color: const Color(0xFF1976D2), width: 2)  // 가운데 카드에 파란 테두리
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1행: 날짜와 요일 (가운데 정렬)
          Center(
            child: Text(
              '${session.dateTime.month}/${session.dateTime.day} ${session.dayOfWeek}',
              style: TextStyle(
                fontSize: 16, // 2포인트 증가 (14→16)
                color: isPast ? Colors.grey : Colors.white,
                fontWeight: isCenter ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 2행: 시작시간 - 끝시간
          Center(
            child: Text(
              '${session.dateTime.hour.toString().padLeft(2, '0')}:${session.dateTime.minute.toString().padLeft(2, '0')} - ${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 12, // 2포인트 증가 (12→14)
                color: isPast ? Colors.grey : Colors.white70,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 3행: 수업명
          Center(
            child: Text(
              session.className,
              style: TextStyle(
                fontSize: 14, // 2포인트 증가 (12→14)
                color: isPast ? Colors.grey : Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 10),
          // 출석 체크박스
          GestureDetector(
            onTap: () => _toggleAttendance(session),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: session.isAttended 
                    ? const Color(0xFF4CAF50)
                    : Colors.transparent,
                border: Border.all(
                  color: session.isAttended 
                      ? const Color(0xFF4CAF50)
                      : Colors.white54,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: session.isAttended
                  ? const Icon(
                      Icons.check,
                      size: 14,
                      color: Colors.white,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
    
    // 툴팁이 있으면 Tooltip으로 감싸고, 없으면 그대로 반환
    if (tooltipMessage.isNotEmpty) {
      return Tooltip(
        message: tooltipMessage,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
        ),
        waitDuration: const Duration(milliseconds: 300),
        child: cardWidget,
      );
    } else {
      return cardWidget;
    }
  }

  bool _isToday(DateTime dateTime) {
    final now = DateTime.now();
    return dateTime.year == now.year &&
           dateTime.month == now.month &&
           dateTime.day == now.day;
  }

  void _toggleAttendance(ClassSession session) async {
    if (widget.selectedStudent == null) return;

    final newAttendanceState = !session.isAttended;
    final now = DateTime.now();
    
    try {
      // 출석 체크 시 등원 시간 설정, 출석 해제 시 등원/하원 시간 초기화
      DateTime? arrivalTime;
      DateTime? departureTime;
      
      if (newAttendanceState) {
        arrivalTime = now; // 출석 체크 시 현재 시간을 등원 시간으로 설정
        departureTime = session.departureTime; // 기존 하원 시간 유지
      } else {
        arrivalTime = null; // 출석 해제 시 등원/하원 시간 모두 초기화
        departureTime = null;
      }

      await DataManager.instance.saveOrUpdateAttendance(
        studentId: widget.selectedStudent!.student.id,
        date: session.dateTime,
        classDateTime: session.dateTime,
        className: session.className,
        isPresent: newAttendanceState,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
      );

      setState(() {
        session.isAttended = newAttendanceState;
      });

      // 성공 피드백
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newAttendanceState ? '출석 체크 완료' : '출석 체크 해제',
          ),
          backgroundColor: newAttendanceState 
              ? const Color(0xFF4CAF50) 
              : const Color(0xFF757575),
          duration: const Duration(milliseconds: 1500),
        ),
      );
    } catch (e) {
      print('[ERROR] 출석 정보 저장 실패: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('출석 정보 저장에 실패했습니다.'),
          backgroundColor: Color(0xFFE53E3E),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (context, attendanceRecords, child) {
        // 출석 기록이 변경되면 수업 세션 다시 로드
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadClassSessions();
        });

        if (widget.selectedStudent == null) {
          return Container(
            height: 160,
            margin: const EdgeInsets.only(bottom: 16, right: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black, width: 1),
            ),
            child: const Center(
              child: Text(
                '학생을 선택해주세요',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 16, right: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 타이틀
                Row(
                  children: [
                    const Text(
                      '출석 체크',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    // 범례
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1976D2).withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          '다음 수업',
                          style: TextStyle(fontSize: 13, color: Colors.white70),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                            border: Border.all(color: const Color(0xFF1976D2), width: 1),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          '최근 수업',
                          style: TextStyle(fontSize: 13, color: Colors.white70),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 수업 목록
                if (_classSessions.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '등록된 수업이 없습니다',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // 전체 너비에서 패딩과 마진을 제외하고 15개 카드로 나눔
                      final totalWidth = constraints.maxWidth;
                      final availableWidth = totalWidth - 32; // 좌우 패딩 16*2
                      final cardMargin = 8; // 카드 간 마진 (horizontal: 4 * 2)
                      final totalMarginWidth = cardMargin * 14; // 15개 카드 사이의 14개 마진
                      final cardWidth = (availableWidth - totalMarginWidth) / 15;
                      
                      // 카드 너비가 너무 작아지지 않도록 최소값 설정
                      final finalCardWidth = cardWidth.clamp(80.0, 200.0);
                      
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _classSessions.asMap().entries.map((entry) {
                            return _buildClassSessionCard(entry.value, entry.key, finalCardWidth);
                          }).toList(),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ClassSession {
  final DateTime dateTime;
  final String className;
  final String dayOfWeek;
  final int duration;
  bool isAttended;
  final DateTime? arrivalTime;
  final DateTime? departureTime;

  ClassSession({
    required this.dateTime,
    required this.className,
    required this.dayOfWeek,
    required this.duration,
    this.isAttended = false,
    this.arrivalTime,
    this.departureTime,
  });
}