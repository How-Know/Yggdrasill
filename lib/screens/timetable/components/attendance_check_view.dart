import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../models/class_info.dart';
import '../../../models/attendance_record.dart';
import '../../../services/data_manager.dart';

class AttendanceCheckView extends StatefulWidget {
  final StudentWithInfo? selectedStudent;
  final int pageIndex;
  final Function(int)? onPageIndexChanged;

  const AttendanceCheckView({
    super.key,
    required this.selectedStudent,
    this.pageIndex = 0,
    this.onPageIndexChanged,
  });

  @override
  State<AttendanceCheckView> createState() => _AttendanceCheckViewState();
}

class _AttendanceCheckViewState extends State<AttendanceCheckView> {
  List<ClassSession> _classSessions = [];
  int _centerIndex = 7; // 가운데 수업 인덱스 (0~14 중 7번째)
  bool _hasPastRecords = false;
  bool _hasFutureCards = false;

  @override
  void initState() {
    super.initState();
    _loadClassSessions();
    // 출석 기록 변경 시 자동 새로고침
    DataManager.instance.attendanceRecordsNotifier.addListener(_onAttendanceRecordsChanged);
  }

  @override
  void dispose() {
    DataManager.instance.attendanceRecordsNotifier.removeListener(_onAttendanceRecordsChanged);
    super.dispose();
  }

  void _onAttendanceRecordsChanged() {
    // 현재 선택된 학생의 출석 기록이 변경되었을 때만 새로고침
    if (widget.selectedStudent != null) {
      _loadClassSessions();
    }
  }

  // 과거 출석 기록이 있는지 확인
  bool _checkHasPastRecords() {
    if (widget.selectedStudent == null) return false;
    
    final studentId = widget.selectedStudent!.student.id;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // DB에서 과거 출석 기록 확인
    final pastRecords = DataManager.instance.attendanceRecords
        .where((record) => record.studentId == studentId)
        .where((record) {
          final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
          return recordDate.isBefore(today);
        })
        .toList();
    
    return pastRecords.isNotEmpty;
  }
  
  // 미래 출석 카드가 생성 가능한지 확인 (현재부터 +2사이클까지)
  bool _checkHasFutureCards() {
    if (widget.selectedStudent == null) return false;
    
    final studentId = widget.selectedStudent!.student.id;
    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList();
    
    // 수업 시간이 등록되어 있고, 현재부터 2사이클 이내면 미래 카드 생성 가능
    return timeBlocks.isNotEmpty && widget.pageIndex < 2;
  }

  @override
  void didUpdateWidget(AttendanceCheckView oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (oldWidget.selectedStudent != widget.selectedStudent) {
      _loadClassSessions();
    } else if (oldWidget.pageIndex != widget.pageIndex) {
      // pageIndex가 변경되었으므로 전체 재생성
      _loadClassSessions();
    } else if (oldWidget.selectedStudent == widget.selectedStudent && widget.selectedStudent != null) {
      // 같은 학생이지만 registration_date가 변경되었는지 확인
      final oldRegistrationDate = oldWidget.selectedStudent?.basicInfo.registrationDate;
      final newRegistrationDate = widget.selectedStudent?.basicInfo.registrationDate;
      
      if (oldRegistrationDate != newRegistrationDate) {
        // registration_date가 변경되었으므로 전체 재생성
        _loadClassSessions();
      } else {
        // 수업 시간이 변경되었을 수 있음 - 전체 재생성
        _updateFutureClassSessions();
      }
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
    
    // 페이지 인덱스에 따라 13주씩 이전 기간 계산
    final weeksOffset = widget.pageIndex * 13;
    final adjustedToday = today.subtract(Duration(days: weeksOffset * 7));
    
    final studentId = widget.selectedStudent!.student.id;
    
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

    // 등록일 확인
    final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
    if (registrationDate == null) {
      return;
    }

    // 🔄 최적화: 과거는 DB에서, 미래만 새로 계산
    final pastSessions = _loadPastSessionsFromDB(studentId, registrationDate, adjustedToday);
    final futureSessions = _generateFutureSessions(timeBlocks, adjustedToday, now);
    
    // 과거 + 미래 세션 합치기
    final allSessions = <ClassSession>[];
    allSessions.addAll(pastSessions);
    allSessions.addAll(futureSessions);

    // 날짜순 정렬
    allSessions.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    _applySessionSelection(allSessions, adjustedToday);
    
    // 화살표 활성화 상태 업데이트
    final newHasPastRecords = _checkHasPastRecords();
    final newHasFutureCards = _checkHasFutureCards();
    
    if (_hasPastRecords != newHasPastRecords || _hasFutureCards != newHasFutureCards) {
      setState(() {
        _hasPastRecords = newHasPastRecords;
        _hasFutureCards = newHasFutureCards;
      });
    }
  }

  // 🗄️ 과거 출석 기록에서 ClassSession 생성 (set_id별로 그룹화)
  List<ClassSession> _loadPastSessionsFromDB(String studentId, DateTime registrationDate, DateTime today) {
    final pastSessions = <ClassSession>[];
    
    // DB에서 해당 학생의 모든 출석 기록 조회
    final attendanceRecords = DataManager.instance.attendanceRecords
        .where((record) => record.studentId == studentId)
        .where((record) {
          final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
          return recordDate.isBefore(today) && !recordDate.isBefore(registrationDate);
        })
        .toList();

    // 🔄 날짜별, set_id별로 출석 기록을 그룹화
    final Map<String, List<AttendanceRecord>> groupedRecords = {};
    
    for (final record in attendanceRecords) {
      // 과거 기록의 setId 추출 시도
      String? extractedSetId;
      final recordDayIndex = record.classDateTime.weekday - 1; // 0(월)~6(일)
      final recordHour = record.classDateTime.hour;
      final recordMinute = record.classDateTime.minute;
      
      // 현재 timeBlocks에서 같은 요일과 비슷한 시간의 블록 찾기
      final timeBlocks = DataManager.instance.studentTimeBlocks
          .where((block) => block.studentId == studentId)
          .where((block) => block.dayIndex == recordDayIndex)
          .toList();
      
      // 시간이 가장 가까운 블록의 setId 사용
      if (timeBlocks.isNotEmpty) {
        StudentTimeBlock? closestBlock;
        int minTimeDiff = 24 * 60; // 최대 24시간 차이
        
        for (final block in timeBlocks) {
          final blockMinutes = block.startHour * 60 + block.startMinute;
          final recordMinutes = recordHour * 60 + recordMinute;
          final timeDiff = (blockMinutes - recordMinutes).abs();
          
          if (timeDiff < minTimeDiff) {
            minTimeDiff = timeDiff;
            closestBlock = block;
          }
        }
        
        // 30분 이내 차이면 같은 수업으로 간주
        if (closestBlock != null && minTimeDiff <= 30) {
          extractedSetId = closestBlock.setId;
        }
      }
      
      // 날짜 + set_id로 그룹 키 생성
      final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
      final groupKey = '${recordDate.millisecondsSinceEpoch}_${extractedSetId ?? 'unknown'}';
      
      groupedRecords.putIfAbsent(groupKey, () => []).add(record);
    }

    // 🎯 그룹화된 기록을 하나의 세션으로 변환
    for (final records in groupedRecords.values) {
      if (records.isEmpty) continue;
      
      // 같은 날짜, 같은 set_id의 기록들을 시간 순으로 정렬
      records.sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
      
      final firstRecord = records.first;
      final lastRecord = records.last;
      
      // 수업 시작시간은 첫 번째 기록, 종료시간은 마지막 기록 사용
      final startTime = firstRecord.classDateTime;
      final endTime = lastRecord.classEndTime;
      
      // 출석 상태: 하나라도 출석했으면 출석으로 처리
      final isAttended = records.any((r) => r.isPresent);
      
      // 등원시간: 가장 빠른 등원시간 사용
      DateTime? earliestArrival;
      for (final record in records) {
        if (record.arrivalTime != null) {
          if (earliestArrival == null || record.arrivalTime!.isBefore(earliestArrival)) {
            earliestArrival = record.arrivalTime;
          }
        }
      }
      
      // 하원시간: 가장 늦은 하원시간 사용
      DateTime? latestDeparture;
      for (final record in records) {
        if (record.departureTime != null) {
          if (latestDeparture == null || record.departureTime!.isAfter(latestDeparture)) {
            latestDeparture = record.departureTime;
          }
        }
      }
      
      // set_id 추출 (첫 번째 기록 기준)
      String? extractedSetId;
      final recordDayIndex = firstRecord.classDateTime.weekday - 1;
      final timeBlocks = DataManager.instance.studentTimeBlocks
          .where((block) => block.studentId == studentId)
          .where((block) => block.dayIndex == recordDayIndex)
          .toList();
      
      if (timeBlocks.isNotEmpty) {
        StudentTimeBlock? closestBlock;
        int minTimeDiff = 24 * 60;
        
        for (final block in timeBlocks) {
          final blockMinutes = block.startHour * 60 + block.startMinute;
          final recordMinutes = firstRecord.classDateTime.hour * 60 + firstRecord.classDateTime.minute;
          final timeDiff = (blockMinutes - recordMinutes).abs();
          
          if (timeDiff < minTimeDiff) {
            minTimeDiff = timeDiff;
            closestBlock = block;
          }
        }
        
        if (closestBlock != null && minTimeDiff <= 30) {
          extractedSetId = closestBlock.setId;
        }
      }

      final session = ClassSession(
        dateTime: startTime,
        className: firstRecord.className,
        dayOfWeek: _getDayOfWeekFromDate(startTime),
        duration: endTime.difference(startTime).inMinutes,
        setId: extractedSetId,
        isAttended: isAttended,
        arrivalTime: earliestArrival,
        departureTime: latestDeparture,
        attendanceStatus: _getAttendanceStatusFromRecords(records),
      );
      pastSessions.add(session);
    }

    return pastSessions;
  }

  // 🔮 미래 수업 세션 생성 (기존 로직 활용)
  List<ClassSession> _generateFutureSessions(List<StudentTimeBlock> timeBlocks, DateTime today, DateTime now) {
    final futureSessions = <ClassSession>[];
    
    // SET_ID별로 timeBlocks 그룹화
    final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
    for (final block in timeBlocks) {
      blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
    }
    
    // 오늘부터 +4주까지 미래 수업 생성
    // 13주 범위로 제한 (91일)
    final endDate = today.add(const Duration(days: 91));
    
    // 각 setId별로 해당 요일에 수업 생성
    for (final entry in blocksBySetId.entries) {
      final blocks = entry.value;
      
      if (blocks.isEmpty) continue;
      
      // 같은 SET_ID의 블록들을 시간순으로 정렬
      blocks.sort((a, b) {
        final aTime = a.startHour * 60 + a.startMinute;
        final bTime = b.startHour * 60 + b.startMinute;
        return aTime.compareTo(bTime);
      });
      
      final firstBlock = blocks.first;
      final lastBlock = blocks.last;
      final dayIndex = firstBlock.dayIndex; // 이 setId의 수업 요일
      
      // 해당 요일에만 수업 생성
      for (DateTime date = today; date.isBefore(endDate); date = date.add(const Duration(days: 1))) {
        // 해당 날짜가 이 setId의 수업 요일인지 확인
        if (date.weekday - 1 != dayIndex) continue;
        
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

        // 기존 출석 기록 확인 (미래에도 기록이 있을 수 있음)
        final attendanceRecord = DataManager.instance.getAttendanceRecord(
          widget.selectedStudent!.student.id,
          classDateTime,
        );
        
        // 디버깅 로그 추가
        if (attendanceRecord != null) {
          print('[DEBUG] 출석 기록 발견 - 학생: ${widget.selectedStudent!.student.name}, 날짜: $classDateTime');
          print('[DEBUG] - 등원: ${attendanceRecord.arrivalTime}, 하원: ${attendanceRecord.departureTime}, isPresent: ${attendanceRecord.isPresent}');
        }

        // 전체 수업 시간 계산 (같은 setId의 모든 블록 포함)
        final startMinutes = firstBlock.startHour * 60 + firstBlock.startMinute;
        final lastBlockEndMinutes = lastBlock.startHour * 60 + lastBlock.startMinute + lastBlock.duration.inMinutes;
        final totalDurationMinutes = lastBlockEndMinutes - startMinutes;

        final session = ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekFromDate(classDateTime),
          duration: totalDurationMinutes,
          setId: entry.key, // setId 포함
          isAttended: attendanceRecord?.isPresent ?? false,
          arrivalTime: attendanceRecord?.arrivalTime,
          departureTime: attendanceRecord?.departureTime,
          attendanceStatus: _getAttendanceStatus(attendanceRecord),
        );
        
        futureSessions.add(session);
      }
    }

    return futureSessions;
  }

  // 📍 13개 세션 선택 및 가운데 인덱스 설정
  void _applySessionSelection(List<ClassSession> allSessions, DateTime today) {
    // 과거 기록을 보는 경우(pageIndex > 0) 파란 테두리 비활성화
    if (widget.pageIndex > 0) {
      setState(() {
        _classSessions = allSessions.length <= 13 ? allSessions : allSessions.sublist(0, 13);
        _centerIndex = -1; // 파란 테두리 비활성화
      });
      return;
    }
    
    // 오늘 수업이 있는지 확인
    int centerIndex = -1;
    
    // 먼저 오늘 수업을 찾기
    for (int i = 0; i < allSessions.length; i++) {
      final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
      if (sessionDate.isAtSameMomentAs(today)) {
        centerIndex = i;
        break;
      }
    }
    
    // 오늘 수업이 없으면 오늘에 가장 가까운 이전 수업 찾기
    if (centerIndex == -1) {
      for (int i = allSessions.length - 1; i >= 0; i--) {
        final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
        if (sessionDate.isBefore(today) || sessionDate.isAtSameMomentAs(today)) {
          centerIndex = i;
          break;
        }
      }
    }
    
    // 여전히 찾지 못했으면 (모든 수업이 미래) 첫 번째 수업을 중심으로
    if (centerIndex == -1 && allSessions.isNotEmpty) {
      centerIndex = 0;
    }
    
    // 13개 수업만 선택 (가운데 수업 기준으로 앞뒤 6개씩)
    if (allSessions.length <= 13) {
      // 전체 수업이 13개 이하면 모두 표시하고 가운데 인덱스 조정
      final actualCenterIndex = centerIndex.clamp(0, allSessions.length - 1);
      setState(() {
        _classSessions = allSessions;
        _centerIndex = actualCenterIndex;
      });
      return;
    }
    
    // 13개보다 많으면 가운데 기준으로 앞뒤 6개씩 선택
    final startIndex = (centerIndex - 6).clamp(0, allSessions.length - 13);
    final endIndex = startIndex + 13;
    final selectedSessions = allSessions.sublist(startIndex, endIndex);

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

  // 출석 상태 계산
  AttendanceStatus _getAttendanceStatus(AttendanceRecord? record) {
    if (record == null) {
      print('[DEBUG] _getAttendanceStatus: record가 null - AttendanceStatus.none 반환');
      return AttendanceStatus.none; // 기록 없음
    }
    
    print('[DEBUG] _getAttendanceStatus: 등원=${record.arrivalTime}, 하원=${record.departureTime}, isPresent=${record.isPresent}');
    
    // 등원/하원 시간 기준으로 먼저 판단
    if (record.arrivalTime != null && record.departureTime != null) {
      print('[DEBUG] _getAttendanceStatus: AttendanceStatus.completed 반환');
      return AttendanceStatus.completed; // 등원+하원 완료
    } else if (record.arrivalTime != null) {
      print('[DEBUG] _getAttendanceStatus: AttendanceStatus.arrived 반환');
      return AttendanceStatus.arrived; // 등원만 완료
    }
    
    // 등원 시간이 없고 isPresent가 false인 경우만 무단결석
    if (!record.isPresent) {
      print('[DEBUG] _getAttendanceStatus: AttendanceStatus.absent 반환');
      return AttendanceStatus.absent; // 무단결석
    }
    
    print('[DEBUG] _getAttendanceStatus: AttendanceStatus.none 반환 (기본)');
    return AttendanceStatus.none; // 기록 없음
  }

  // 🔄 여러 출석 기록에서 최종 출석 상태 계산
  AttendanceStatus _getAttendanceStatusFromRecords(List<AttendanceRecord> records) {
    if (records.isEmpty) return AttendanceStatus.none;
    
    // 하나라도 등원+하원이 완료된 기록이 있으면 completed
    if (records.any((r) => r.arrivalTime != null && r.departureTime != null)) {
      return AttendanceStatus.completed;
    }
    
    // 하나라도 등원한 기록이 있으면 arrived
    if (records.any((r) => r.arrivalTime != null)) {
      return AttendanceStatus.arrived;
    }
    
    // 모든 기록이 불참이면 absent
    if (records.every((r) => !r.isPresent)) {
      return AttendanceStatus.absent;
    }
    
    return AttendanceStatus.none;
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

  // 해당 사이클 내에서 수업 순서 계산 (수업명 기준)
  int _calculateSessionNumberInCycle(DateTime registrationDate, DateTime sessionDate, String className) {
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
    

    
    // 🔥 새로운 접근: 현재 생성된 모든 세션에서 같은 수업명인 것들만 필터링
    final sameClassSessions = _classSessions
        .where((session) => session.className == className)
        .where((session) {
          final sessionDateOnly = DateTime(session.dateTime.year, session.dateTime.month, session.dateTime.day);
          return !sessionDateOnly.isBefore(cycleStartDate) && !sessionDateOnly.isAfter(cycleEndDate);
        })
        .toList();
    
    // 날짜순 정렬
    sameClassSessions.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    

    
    // 해당 수업이 몇 번째인지 찾기
    final sessionDateOnly = DateTime(sessionDate.year, sessionDate.month, sessionDate.day);
    final sessionIndex = sameClassSessions.indexWhere((session) {
      final sesDateOnly = DateTime(session.dateTime.year, session.dateTime.month, session.dateTime.day);
      final sesTime = Duration(hours: session.dateTime.hour, minutes: session.dateTime.minute);
      final targetTime = Duration(hours: sessionDate.hour, minutes: sessionDate.minute);
      return sesDateOnly.isAtSameMomentAs(sessionDateOnly) && sesTime == targetTime;
    });
    

    
    return sessionIndex >= 0 ? sessionIndex + 1 : 1;
  }

  Widget _buildClassSessionCard(ClassSession session, int index, double cardWidth) {
    final isCenter = index == _centerIndex;
    final isPast = session.dateTime.isBefore(DateTime.now());
    
    // 다음 수업(미래 수업 중 가장 가까운 것) 찾기
    final now = DateTime.now();
    final isNextClass = !isPast && _classSessions.where((s) => s.dateTime.isAfter(now)).isNotEmpty && 
        session.dateTime == _classSessions.where((s) => s.dateTime.isAfter(now)).first.dateTime;
    
    // 수업 번호 계산 (사이클-순서-수업명)
    String classNumber = '';
    if (widget.selectedStudent != null) {
      final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
      if (registrationDate != null) {

        final cycleNumber = _calculateCycleNumber(registrationDate, session.dateTime);
        final sessionNumber = _calculateSessionNumberInCycle(registrationDate, session.dateTime, session.className);
        classNumber = '$cycleNumber-$sessionNumber-${session.className}';

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
            onTap: () => _handleAttendanceClick(session),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _getCheckboxColor(session.attendanceStatus),
                border: Border.all(
                  color: _getCheckboxBorderColor(session.attendanceStatus),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _getCheckboxIcon(session.attendanceStatus),
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

  // 체크박스 색상 계산
  Color _getCheckboxColor(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.completed:
        return const Color(0xFF4CAF50); // 초록색 (출석 완료)
      case AttendanceStatus.arrived:
        return const Color(0xFF2196F3); // 파란색 (등원만)
      case AttendanceStatus.absent:
        return const Color(0xFFE53E3E); // 빨간색 (무단결석)
      case AttendanceStatus.none:
        return Colors.transparent; // 투명 (기록 없음)
    }
  }

  // 체크박스 테두리 색상 계산
  Color _getCheckboxBorderColor(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.completed:
        return const Color(0xFF4CAF50);
      case AttendanceStatus.arrived:
        return const Color(0xFF2196F3);
      case AttendanceStatus.absent:
        return const Color(0xFFE53E3E);
      case AttendanceStatus.none:
        return Colors.white54;
    }
  }

  // 체크박스 아이콘 계산
  Widget? _getCheckboxIcon(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.completed:
        return const Icon(Icons.check, size: 14, color: Colors.white);
      case AttendanceStatus.arrived:
        return const Icon(Icons.login, size: 12, color: Colors.white);
      case AttendanceStatus.absent:
        return const Icon(Icons.close, size: 14, color: Colors.white);
      case AttendanceStatus.none:
        return null;
    }
  }

  void _handleAttendanceClick(ClassSession session) async {
    if (widget.selectedStudent == null) return;

    final now = DateTime.now();
    
    // 무단결석인 경우 첫 클릭으로 출석완료 처리
    if (session.attendanceStatus == AttendanceStatus.absent) {
      final classStartTime = session.dateTime;
      final classEndTime = session.dateTime.add(Duration(minutes: session.duration));
      
      try {
        await DataManager.instance.saveOrUpdateAttendance(
          studentId: widget.selectedStudent!.student.id,
          classDateTime: session.dateTime,
          classEndTime: classEndTime,
          className: session.className,
          isPresent: true,
          arrivalTime: classStartTime, // 수업 시작 시간
          departureTime: classEndTime, // 수업 종료 시간
        );

        setState(() {
          session.isAttended = true;
          session.arrivalTime = classStartTime;
          session.departureTime = classEndTime;
          session.attendanceStatus = AttendanceStatus.completed;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('출석으로 변경되었습니다'),
            backgroundColor: Color(0xFF4CAF50),
            duration: Duration(milliseconds: 1500),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('출석 변경에 실패했습니다'),
            backgroundColor: Color(0xFFE53E3E),
          ),
        );
      }
      return;
    }
    
    // 아직 시작하지 않은 수업인지 확인 (수업 시작 시간이 현재 시간보다 미래인 경우)
    if (session.dateTime.isAfter(now)) {
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
      final classStartTime = session.dateTime;
      final classEndTime = session.dateTime.add(Duration(minutes: session.duration));
      
      DateTime? arrivalTime;
      DateTime? departureTime;
      bool isPresent;
      AttendanceStatus newStatus;
      String message;
      
      switch (session.attendanceStatus) {
        case AttendanceStatus.none:
          // 첫 번째 클릭: 등원 기록
          arrivalTime = now;
          departureTime = null;
          isPresent = true; // 등원 상태로 변경
          newStatus = AttendanceStatus.arrived;
          message = '등원 시간 기록 완료';
          break;
          
        case AttendanceStatus.arrived:
          // 두 번째 클릭: 하원 기록
          arrivalTime = session.arrivalTime; // 기존 등원 시간 유지
          departureTime = now;
          isPresent = true; // 출석 완료
          newStatus = AttendanceStatus.completed;
          message = '하원 시간 기록 완료';
          break;
          
        case AttendanceStatus.completed:
          // 출석완료 클릭: 수정 다이얼로그 표시
          await _showEditAttendanceDialog(session);
          return;
          
        case AttendanceStatus.absent:
          // 무단결석은 위에서 처리됨
          return;
      }

      await DataManager.instance.saveOrUpdateAttendance(
        studentId: widget.selectedStudent!.student.id,
        classDateTime: session.dateTime,
        classEndTime: classEndTime,
        className: session.className,
        isPresent: isPresent,
        arrivalTime: arrivalTime,
        departureTime: departureTime,
      );

      setState(() {
        session.isAttended = isPresent;
        session.arrivalTime = arrivalTime;
        session.departureTime = departureTime;
        session.attendanceStatus = newStatus;
      });

      // 성공 피드백
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: newStatus == AttendanceStatus.completed 
              ? const Color(0xFF4CAF50) 
              : newStatus == AttendanceStatus.arrived
                  ? const Color(0xFF2196F3)
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

  // 무단결석 수업 시간 수정 다이얼로그
  Future<void> _showEditAttendanceDialog(ClassSession session) async {
    DateTime selectedDate = session.dateTime;
    TimeOfDay selectedArrivalTime = TimeOfDay.fromDateTime(session.dateTime);
    TimeOfDay selectedDepartureTime = TimeOfDay.fromDateTime(
      session.dateTime.add(Duration(minutes: session.duration))
    );

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              title: const Text(
                '출석 시간 수정',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 날짜 선택
                    ListTile(
                      leading: const Icon(Icons.calendar_today, color: Colors.white70),
                      title: Text(
                        '날짜: ${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () async {
                        final DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                          builder: (BuildContext context, Widget? child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: const ColorScheme(
                                  brightness: Brightness.dark,
                                  primary: Color(0xFF1976D2),
                                  onPrimary: Colors.white,
                                  secondary: Color(0xFF1976D2),
                                  onSecondary: Colors.white,
                                  error: Color(0xFFB00020),
                                  onError: Colors.white,
                                  background: Color(0xFF18181A),
                                  onBackground: Colors.white,
                                  surface: Color(0xFF18181A),
                                  onSurface: Colors.white,
                                ),
                                dialogBackgroundColor: const Color(0xFF18181A),
                              ),
                              child: child!,
                            );
                          },
                        );
                        if (picked != null) {
                          setDialogState(() {
                            selectedDate = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              selectedDate.hour,
                              selectedDate.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    // 등원 시간 선택
                    ListTile(
                      leading: const Icon(Icons.login, color: Colors.white70),
                      title: Text(
                        '등원 시간: ${selectedArrivalTime.format(context)}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () async {
                        final TimeOfDay? picked = await _showCustomTimePicker(
                          context,
                          selectedArrivalTime,
                        );
                        if (picked != null) {
                          setDialogState(() {
                            selectedArrivalTime = picked;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    // 하원 시간 선택
                    ListTile(
                      leading: const Icon(Icons.logout, color: Colors.white70),
                      title: Text(
                        '하원 시간: ${selectedDepartureTime.format(context)}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () async {
                        final TimeOfDay? picked = await _showCustomTimePicker(
                          context,
                          selectedDepartureTime,
                        );
                        if (picked != null) {
                          setDialogState(() {
                            selectedDepartureTime = picked;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소', style: TextStyle(color: Colors.grey)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop({'action': 'delete'});
                  },
                  child: const Text('출석 해제', style: TextStyle(color: Color(0xFFE53E3E))),
                ),
                TextButton(
                  onPressed: () {
                    final arrivalDateTime = DateTime(
                      selectedDate.year,
                      selectedDate.month,
                      selectedDate.day,
                      selectedArrivalTime.hour,
                      selectedArrivalTime.minute,
                    );
                    final departureDateTime = DateTime(
                      selectedDate.year,
                      selectedDate.month,
                      selectedDate.day,
                      selectedDepartureTime.hour,
                      selectedDepartureTime.minute,
                    );
                    
                    Navigator.of(context).pop({
                      'action': 'update',
                      'arrivalTime': arrivalDateTime,
                      'departureTime': departureDateTime,
                    });
                  },
                  child: const Text('확인', style: TextStyle(color: Color(0xFF1976D2))),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null && mounted) {
      try {
        final classEndTime = session.dateTime.add(Duration(minutes: session.duration));
        
        if (result['action'] == 'delete') {
          // 출석 해제 - 무단결석으로 기록
          await DataManager.instance.saveOrUpdateAttendance(
            studentId: widget.selectedStudent!.student.id,
            classDateTime: session.dateTime,
            classEndTime: classEndTime,
            className: session.className,
            isPresent: false,
            arrivalTime: null,
            departureTime: null,
          );

          setState(() {
            session.isAttended = false;
            session.arrivalTime = null;
            session.departureTime = null;
            session.attendanceStatus = AttendanceStatus.absent;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('출석이 해제되었습니다.'),
              backgroundColor: Color(0xFFE53E3E),
              duration: Duration(milliseconds: 1500),
            ),
          );
        } else {
          // 출석 시간 수정
          await DataManager.instance.saveOrUpdateAttendance(
            studentId: widget.selectedStudent!.student.id,
            classDateTime: session.dateTime,
            classEndTime: classEndTime,
            className: session.className,
            isPresent: true,
            arrivalTime: result['arrivalTime'],
            departureTime: result['departureTime'],
          );

          setState(() {
            session.isAttended = true;
            session.arrivalTime = result['arrivalTime'];
            session.departureTime = result['departureTime'];
            session.attendanceStatus = AttendanceStatus.completed;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('출석 시간이 수정되었습니다.'),
              backgroundColor: Color(0xFF4CAF50),
              duration: Duration(milliseconds: 1500),
            ),
          );
        }
      } catch (e) {
        print('[ERROR] 출석 처리 실패: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('출석 처리에 실패했습니다.'),
            backgroundColor: Color(0xFFE53E3E),
          ),
        );
      }
    }
  }

  // 설정 스타일의 커스텀 시간 선택기
  Future<TimeOfDay?> _showCustomTimePicker(BuildContext context, TimeOfDay initialTime) {
    return showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              secondary: Color(0xFF1976D2),
              onSecondary: Colors.white,
              error: Color(0xFFB00020),
              onError: Colors.white,
              background: Color(0xFF18181A),
              onBackground: Colors.white,
              surface: Color(0xFF18181A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF18181A),
              hourMinuteColor: Color(0xFF1976D2),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF1976D2),
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: Color(0xFF1976D2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(24))
              ),
              helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: Color(0xFF1976D2),
            ),
          ),
          child: Localizations.override(
            context: context,
            locale: const Locale('ko'),
            delegates: [
              ...GlobalMaterialLocalizations.delegates,
            ],
            child: Builder(
              builder: (context) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                  child: child!,
                );
              },
            ),
          ),
        );
      },
    );
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
              color: const Color(0xFF18181A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFF18181A), width: 1),
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
            color: const Color(0xFF18181A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF18181A), width: 1),
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
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16), // 타이틀과 범례 사이 간격
                    // 범례
                    Wrap(
                      children: [
                        // 다음 수업
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
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
                          ],
                        ),
                        const SizedBox(width: 12),
                        // 최근 수업
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
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
                        const SizedBox(width: 12),
                        // 출석 완료
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4CAF50),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const Icon(Icons.check, size: 10, color: Colors.white),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '출석완료',
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        // 등원만
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2196F3),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const Icon(Icons.login, size: 10, color: Colors.white),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '등원만',
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        // 무단결석
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE53E3E),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const Icon(Icons.close, size: 10, color: Colors.white),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '무단결석',
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(), // 범례와 화살표 사이 공간
                    // 왼쪽 화살표 (현재로 이동)
                    IconButton(
                      onPressed: (widget.pageIndex > 0 && widget.onPageIndexChanged != null) ? () {
                        widget.onPageIndexChanged!(widget.pageIndex - 1);
                      } : null,
                      icon: Icon(
                        Icons.arrow_back_ios,
                        color: widget.pageIndex > 0 ? Colors.white70 : Colors.white24,
                        size: 20,
                      ),
                    ),
                    // 오른쪽 화살표 (과거로 이동)
                    IconButton(
                      onPressed: (widget.onPageIndexChanged != null && widget.pageIndex < 2 && _hasPastRecords) ? () {
                        widget.onPageIndexChanged!(widget.pageIndex + 1);
                      } : null,
                      icon: Icon(
                        Icons.arrow_forward_ios,
                        color: (widget.pageIndex < 2 && _hasPastRecords) ? Colors.white70 : Colors.white24,
                        size: 20,
                      ),
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
                        style: TextStyle(color: Colors.white54, fontSize: 17),
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

enum AttendanceStatus {
  none,       // 기록 없음
  arrived,    // 등원만 완료
  completed,  // 등원+하원 완료
  absent,     // 무단결석
}

class ClassSession {
  final DateTime dateTime;
  final String className;
  final String dayOfWeek;
  final int duration;
  final String? setId; // 수업 회차 계산을 위한 setId 추가
  bool isAttended;
  DateTime? arrivalTime;
  DateTime? departureTime;
  AttendanceStatus attendanceStatus;

  ClassSession({
    required this.dateTime,
    required this.className,
    required this.dayOfWeek,
    required this.duration,
    this.setId,
    this.isAttended = false,
    this.arrivalTime,
    this.departureTime,
    this.attendanceStatus = AttendanceStatus.none,
  });
}