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
    } else if (oldWidget.selectedStudent == widget.selectedStudent && widget.selectedStudent != null) {
      // 같은 학생이지만 수업 시간이 변경되었을 수 있음 - 전체 재생성
      _updateFutureClassSessions();
    }
  }

  // 수업 시간 변경 시 전체 세션 재생성 (과거 출석 기록 보존)
  void _updateFutureClassSessions() {
    // 단순히 _loadClassSessions를 호출하여 전체 재생성
    _loadClassSessions();
  }

  void _loadClassSessions() {
    if (widget.selectedStudent == null) {
      setState(() {
        _classSessions = [];
      });
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    final studentId = widget.selectedStudent!.student.id;
    final sessions = <ClassSession>[];
    
    // 현재 timeBlocks에서 duration 정보 가져오기
    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList();
    
    if (timeBlocks.isEmpty) {
      setState(() {
        _classSessions = [];
        _centerIndex = 0;
      });
      return;
    }

    // SET_ID별로 timeBlocks 그룹화
    final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
    for (final block in timeBlocks) {
      blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
    }

    // 등록일 확인
    final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
    if (registrationDate == null) {
      return;
    }
    
    // 등록일부터 현재일 기준 +4주까지 수업 일정 생성
    final startDate = registrationDate;
    final endDate = now.add(const Duration(days: 28)); // 현재일 + 4주
    
    for (DateTime date = startDate; date.isBefore(endDate); date = date.add(const Duration(days: 1))) {
      for (final entry in blocksBySetId.entries) {
        final setId = entry.key;
        final blocks = entry.value;
        
        if (blocks.isEmpty) continue;
        
        // 각 SET_ID별로 하나의 카드만 생성 (첫 번째 블록 기준)
        final firstBlock = blocks.first;
        
        // 해당 날짜가 수업 요일인지 확인
        if (date.weekday - 1 != firstBlock.dayIndex) continue; // weekday: 1(월)~7(일), dayIndex: 0(월)~6(일)
        
        final classDateTime = DateTime(
          date.year,
          date.month,
          date.day,
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
          date,
          classDateTime,
        );

        final sessionFromTimeBlock = ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekFromDate(classDateTime),
          duration: firstBlock.duration.inMinutes, // Duration을 int(분)로 변환
          isAttended: attendanceRecord?.isPresent ?? false, // 기존 출석 기록 반영
          arrivalTime: attendanceRecord?.arrivalTime,
          departureTime: attendanceRecord?.departureTime,
        );
        
        sessions.add(sessionFromTimeBlock);
      }
    }

    // 날짜순 정렬
    sessions.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    // 오늘 수업이 있는지 확인
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
    
    // 13개 수업만 선택 (가운데 수업 기준으로 앞뒤 6개씩)
    if (sessions.length <= 13) {
      // 전체 수업이 13개 이하면 모두 표시하고 가운데 인덱스 조정
      final actualCenterIndex = centerIndex.clamp(0, sessions.length - 1);
      setState(() {
        _classSessions = sessions;
        _centerIndex = actualCenterIndex;
      });
      return;
    }
    
    // 13개보다 많으면 가운데 기준으로 앞뒤 6개씩 선택
    final startIndex = (centerIndex - 6).clamp(0, sessions.length - 13);
    final endIndex = startIndex + 13;
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

  // 실제 날짜를 기반으로 요일을 계산
  String _getDayOfWeekFromDate(DateTime date) {
    const days = ['일', '월', '화', '수', '목', '금', '토'];
    // DateTime.weekday: 1(월요일) ~ 7(일요일)
    // 우리 배열: 0(일요일) ~ 6(토요일)
    int dayIndex = date.weekday % 7; // 1~7 -> 1~0, 즉 월~일 -> 월~일
    return days[dayIndex];
  }

  // 수강 사이클 번호 계산 (월 기준)
  int _calculateCycleNumber(DateTime registrationDate, DateTime sessionDate) {
    int months = (sessionDate.year - registrationDate.year) * 12 + (sessionDate.month - registrationDate.month);
    if (sessionDate.day < registrationDate.day) {
      months--;
    }
    return (months + 1).clamp(1, double.infinity).toInt();
  }

  // 해당 사이클 내에서 수업 순서 계산
  int _calculateSessionNumberInCycle(DateTime registrationDate, DateTime sessionDate) {
    if (widget.selectedStudent == null) return 1;
    
    // 해당 사이클의 시작일 계산
    final cycleNumber = _calculateCycleNumber(registrationDate, sessionDate);
    DateTime cycleStartDate;
    if (cycleNumber == 1) {
      cycleStartDate = registrationDate;
    } else {
      cycleStartDate = DateTime(
        registrationDate.year + ((registrationDate.month + cycleNumber - 2) ~/ 12),
        ((registrationDate.month + cycleNumber - 2) % 12) + 1,
        registrationDate.day,
      );
    }
    
    // 해당 사이클의 끝일 계산
    final cycleEndDate = DateTime(
      registrationDate.year + ((registrationDate.month + cycleNumber - 1) ~/ 12),
      ((registrationDate.month + cycleNumber - 1) % 12) + 1,
      registrationDate.day,
    ).subtract(const Duration(days: 1));
    
    // 해당 학생의 수업 요일들 가져오기
    final studentTimeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == widget.selectedStudent!.student.id)
        .toList();
    
    if (studentTimeBlocks.isEmpty) return 1;
    
    // 해당 사이클 내의 모든 수업 날짜 생성 (중복 제거)
    final Set<DateTime> classDateSet = {};
    final studentDayIndices = studentTimeBlocks.map((block) => block.dayIndex).toSet();
    
    for (DateTime date = cycleStartDate; date.isBefore(cycleEndDate.add(const Duration(days: 1))); date = date.add(const Duration(days: 1))) {
      // 해당 날짜가 수업 요일 중 하나인지 확인
      if (studentDayIndices.contains(date.weekday - 1)) { // weekday: 1(월)~7(일), dayIndex: 0(월)~6(일)
        classDateSet.add(DateTime(date.year, date.month, date.day));
      }
    }
    
    final List<DateTime> classDatesinCycle = classDateSet.toList();
    
    // 날짜 순으로 정렬
    classDatesinCycle.sort();
    
    // 해당 수업이 몇 번째인지 찾기
    final sessionDateOnly = DateTime(sessionDate.year, sessionDate.month, sessionDate.day);
    final sessionIndex = classDatesinCycle.indexWhere((date) => date.isAtSameMomentAs(sessionDateOnly));
    
    return sessionIndex >= 0 ? sessionIndex + 1 : 1;
  }

  Widget _buildClassSessionCard(ClassSession session, int index, double cardWidth) {
    final isCenter = index == _centerIndex;
    final isPast = session.dateTime.isBefore(DateTime.now());
    
    // 다음 수업(미래 수업 중 가장 가까운 것) 찾기
    final now = DateTime.now();
    final isNextClass = !isPast && _classSessions.where((s) => s.dateTime.isAfter(now)).isNotEmpty && 
        session.dateTime == _classSessions.where((s) => s.dateTime.isAfter(now)).first.dateTime;
    
    // 수업 번호 계산 (사이클-순서)
    String classNumber = '';
    if (widget.selectedStudent != null) {
      final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
      if (registrationDate != null) {
        final cycleNumber = _calculateCycleNumber(registrationDate, session.dateTime);
        final sessionNumber = _calculateSessionNumberInCycle(registrationDate, session.dateTime);
        classNumber = '$cycleNumber-$sessionNumber';
      }
    }
    
    // 등원/하원 시간 정보가 있으면 툴팁 메시지 생성
    String tooltipMessage = '';
    
    // 수업 번호 추가
    if (classNumber.isNotEmpty) {
      tooltipMessage += '$classNumber';
    }
    
    if (session.arrivalTime != null || session.departureTime != null) {
      if (session.arrivalTime != null) {
        final arrivalTime = session.arrivalTime!;
        if (tooltipMessage.isNotEmpty) tooltipMessage += '\n';
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
    
    // 마진을 조건부로 설정 (첫번째/마지막 카드는 한쪽 마진만)
    EdgeInsets cardMargin;
    if (index == 0) {
      cardMargin = const EdgeInsets.only(right: 8); // 첫 번째 카드
    } else if (index == _classSessions.length - 1) {
      cardMargin = EdgeInsets.zero; // 마지막 카드
    } else {
      cardMargin = const EdgeInsets.only(right: 8); // 중간 카드들
    }
    
    Widget cardWidget = Container(
      width: cardWidth,
      height: 140, // 카드 높이 추가 증가 (130→140)
      margin: cardMargin,
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
    
    // 아직 시작하지 않은 수업인지 확인 (수업 시작 시간이 현재 시간보다 미래인 경우)
    if (newAttendanceState && session.dateTime.isAfter(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('아직 시작하지 않은 수업입니다.'),
          backgroundColor: Color(0xFFFF9800),
          duration: Duration(milliseconds: 2000),
        ),
      );
      return;
    }
    
    try {
      // 수업 시간을 기준으로 등원/하원 시간 설정
      final classStartTime = session.dateTime;
      final classEndTime = session.dateTime.add(Duration(minutes: session.duration));
      
      DateTime? arrivalTime;
      DateTime? departureTime;
      
      if (newAttendanceState) {
        arrivalTime = classStartTime; // 수업 시작 시간을 등원 시간으로 설정
        departureTime = classEndTime; // 수업 끝 시간을 하원 시간으로 설정
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
        if (newAttendanceState) {
          session.arrivalTime = arrivalTime;
          session.departureTime = departureTime;
        } else {
          session.arrivalTime = null;
          session.departureTime = null;
        }
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
                      // 전체 너비에서 패딩을 제외하고 카드로 나눔
                      final totalWidth = constraints.maxWidth;
                      final availableWidth = totalWidth;
                      final cardMargin = 8; // 카드 간 마진
                      final totalMarginWidth = cardMargin * (_classSessions.length - 1); // 카드 사이의 마진 (마지막 카드 제외)
                      final cardWidth = (availableWidth - totalMarginWidth) / _classSessions.length;
                      
                      // 카드 너비가 너무 작아지지 않도록 최소값 설정
                      final finalCardWidth = cardWidth.clamp(80.0, 200.0);
                      
                      return Row(
                        children: _classSessions.asMap().entries.map((entry) {
                          return _buildClassSessionCard(entry.value, entry.key, finalCardWidth);
                        }).toList(),
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
  DateTime? arrivalTime;
  DateTime? departureTime;

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