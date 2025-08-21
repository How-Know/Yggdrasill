import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../models/session_override.dart';
import '../../../models/class_info.dart';
import '../../../models/attendance_record.dart';
import '../../../services/data_manager.dart';

class AttendanceCheckView extends StatefulWidget {
  final StudentWithInfo? selectedStudent;
  final int pageIndex;
  final Function(int)? onPageIndexChanged;
  final bool autoOpenListOnStart;
  final Future<void> Function(ClassSession session)? onReplaceSelected;
  final bool listOnly; // 리스트 다이얼로그만 사용하고 본문 UI는 렌더링하지 않음

  const AttendanceCheckView({
    super.key,
    required this.selectedStudent,
    this.pageIndex = 0,
    this.onPageIndexChanged,
    this.autoOpenListOnStart = false,
    this.onReplaceSelected,
    this.listOnly = false,
  });

  @override
  State<AttendanceCheckView> createState() => _AttendanceCheckViewState();
}

class _AttendanceCheckViewState extends State<AttendanceCheckView> {
  List<ClassSession> _classSessions = [];
  int _centerIndex = 7; // 가운데 수업 인덱스 (0~14 중 7번째)
  bool _hasPastRecords = false;
  bool _hasFutureCards = false;
  bool _isListView = false; // (미사용) 리스트는 다이얼로그로 표시
  
  // 스마트 슬라이딩을 위한 상태 변수들
  List<ClassSession> _allSessions = []; // 전체 세션 저장
  int _currentStartIndex = 0; // 현재 화면의 시작 인덱스
  // 화면당 표시 카드 수 및 센터 인덱스(0-base)
  static const int _visibleCount = 11;
  static const int _halfCenter = _visibleCount ~/ 2; // 5
  int _blueBorderAbsoluteIndex = -1; // 파란 테두리의 절대 인덱스
  
  // 디바운싱을 위한 변수들
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _loadClassSessions();
    // 출석 기록 변경 시 자동 새로고침
    DataManager.instance.attendanceRecordsNotifier.addListener(_onAttendanceRecordsChanged);
    // 보강/예외 변경 시 자동 새로고침
    DataManager.instance.sessionOverridesNotifier.addListener(_onAttendanceRecordsChanged);
    if (widget.autoOpenListOnStart && widget.selectedStudent != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSessionListDialog();
      });
    }
  }

  @override
  void dispose() {
    DataManager.instance.attendanceRecordsNotifier.removeListener(_onAttendanceRecordsChanged);
    DataManager.instance.sessionOverridesNotifier.removeListener(_onAttendanceRecordsChanged);
    super.dispose();
  }

  void _onAttendanceRecordsChanged() async {
    // 디바운싱 및 안전성 체크
    if (_isUpdating || !mounted || widget.selectedStudent == null) return;
    
    _isUpdating = true;
    print('[DEBUG][AttendanceCheckView] 출석 기록 변경 감지, _loadClassSessions 호출');
    
    // 짧은 지연을 추가하여 연속된 업데이트 방지
    await Future.delayed(const Duration(milliseconds: 50));
    
    if (mounted && widget.selectedStudent != null) {
      _loadClassSessions();
    }
    
    _isUpdating = false;
  }

  DateTime _toMonday(DateTime d) {
    // DateTime.weekday: 1=Mon..7=Sun
    final offset = d.weekday - DateTime.monday; // 0 for Monday, 6 for Sunday
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: offset));
  }

  int _computeWeekNumber(DateTime registrationDate, DateTime sessionDate) {
    // 주차 기준: 월~일 고정. 등록 주의 월요일을 1주차로 간주하여 세션 주의 월요일까지의 주차를 계산
    final regMon = _toMonday(registrationDate);
    final sesMon = _toMonday(sessionDate);
    final diff = sesMon.difference(regMon).inDays;
    final weeks = diff >= 0 ? (diff ~/ 7) : 0;
    return weeks + 1;
  }

  int? _getWeeklyOrderForSet(String? setId, List<StudentTimeBlock> blocks) {
    if (setId == null) return null;
    try {
      return blocks.firstWhere((b) => b.setId == setId).weeklyOrder;
    } catch (_) {
      return null;
    }
  }

  // 리스트용 상태 Pill
  Widget _buildStatusPill(AttendanceStatus status) {
    String label;
    switch (status) {
      case AttendanceStatus.completed:
        label = '완료';
        break;
      case AttendanceStatus.arrived:
        label = '등원';
        break;
      case AttendanceStatus.absent:
        label = '결석';
        break;
      case AttendanceStatus.none:
      default:
        label = '미기록';
        break;
    }
    final bg = _getCheckboxColor(status);
    final border = _getCheckboxBorderColor(status);
    final icon = _getCheckboxIcon(status);
    final pillWidth = 84.0; // 너비 유지
    final Color labelColor = () {
      switch (status) {
        case AttendanceStatus.completed:
          return const Color(0xFF4CAF50);
        case AttendanceStatus.absent:
          return const Color(0xFFE53E3E);
        case AttendanceStatus.arrived:
        case AttendanceStatus.none:
        default:
          return Colors.white70;
      }
    }();
    return SizedBox(
      width: pillWidth,
      child: Container(
        height: 36, // 기존의 2배 수준으로 확장
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: border, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
            child: (icon != null)
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
                        child: icon,
                      ),
                      const SizedBox(width: 8),
                      Text(label, style: TextStyle(color: labelColor, fontSize: 13, height: 1.0)),
                    ],
                  )
                : Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: labelColor, fontSize: 13, height: 1.0),
                  ),
        ),
      ),
    );
  }

  Future<void> _showSessionListDialog() async {
    final itemHeight = 76.0;
    final totalCount = _allSessions.isNotEmpty ? _allSessions.length : _classSessions.length;
    final visibleCount = totalCount < 8 ? totalCount : 8;
    final dialogHeight = (visibleCount * itemHeight) + 28; // 여백 약간 증가
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final sessions = _allSessions.isNotEmpty ? _allSessions : _classSessions;
            final ScrollController _listController = ScrollController();
            Future<void> _selectMonthAndJump() async {
              final DateTime now = DateTime.now();
              final DateTime? picked = await showDatePicker(
                context: context,
                initialDate: DateTime(now.year, now.month, 1),
                firstDate: DateTime(now.year - 5, 1, 1),
                lastDate: DateTime(now.year + 5, 12, 31),
                locale: const Locale('ko', 'KR'),
                builder: (context, child) {
                  return Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: Color(0xFF1976D2),
                        onPrimary: Colors.white,
                        surface: Color(0xFF2A2A2A),
                        onSurface: Colors.white,
                      ),
                    ),
                    child: child!,
                  );
                },
              );
              if (picked == null) return;
              final int targetIndex = sessions.indexWhere((s) =>
                  s.dateTime.year == picked.year && s.dateTime.month == picked.month);
              if (targetIndex == -1) return;
              const double separatorHeight = 12.0;
              final double offset = targetIndex * (itemHeight + separatorHeight);
              if (_listController.hasClients) {
                _listController.animateTo(
                  offset,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                );
              }
            }
            return AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
              title: Row(
                children: [
                  const Text('수업 일정', style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _selectMonthAndJump,
                    icon: const Icon(Icons.event, color: Colors.white70, size: 18),
                    label: const Text('년월 이동', style: TextStyle(color: Colors.white70)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      foregroundColor: Colors.white70,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 560,
                height: dialogHeight,
                child: Scrollbar(
                  controller: _listController,
                  thumbVisibility: true,
                  child: ListView.separated(
                    controller: _listController,
                    itemCount: sessions.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                    itemBuilder: (context, idx) {
                      final s = sessions[idx];
                      final dateStr = '${s.dateTime.year}-${s.dateTime.month.toString().padLeft(2,'0')}-${s.dateTime.day.toString().padLeft(2,'0')} (${s.dayOfWeek})';

                      // 고스트/보강 플래그
                      final bool isGhost = s.isOverrideOriginalGhost;
                      final bool isReplacement = s.isOverrideReplacement;

                      // 주차/weekly_order 계산 (원본 앵커 시간 기준)
                      final registrationDate = widget.selectedStudent?.basicInfo.registrationDate;
                      final DateTime anchorDateTime = s.overrideOriginalDateTime ?? s.dateTime;
                      final int? displayWeekNumber = registrationDate != null
                          ? _computeWeekNumber(registrationDate, anchorDateTime)
                          : s.weekNumber;
                      int? displayWeeklyOrder = s.weeklyOrder;
                      if (displayWeeklyOrder == null && s.setId != null && widget.selectedStudent != null) {
                        final blocks = DataManager.instance.studentTimeBlocks
                            .where((b) => b.studentId == widget.selectedStudent!.student.id)
                            .toList();
                        displayWeeklyOrder = _getWeeklyOrderForSet(s.setId, blocks);
                      }

                       Offset? tapDownPosition;
                       return GestureDetector(
                         behavior: HitTestBehavior.opaque,
                         onTapDown: (details) => tapDownPosition = details.globalPosition,
                         onTap: () async {
                           // 리스트 아이템 클릭 시 출석체크 카드와 동일한 메뉴 제공
                           if (tapDownPosition == null) return;
                           final now = DateTime.now();
                           final selected = await showMenu<String>(
                             context: context,
                             position: RelativeRect.fromLTRB(
                               tapDownPosition!.dx,
                               tapDownPosition!.dy,
                               tapDownPosition!.dx,
                               tapDownPosition!.dy,
                             ),
                             color: const Color(0xFF1F1F1F),
                              items: isReplacement
                                  ? [
                                      _menuItem('replacement_change', '보강시간 변경'),
                                      _menuItem('replacement_cancel', '보강 취소'),
                                    ]
                                  : (isGhost && _hasSkipOverrideFor(s))
                                      ? [
                                          _menuItem('skip_cancel', '휴강 취소'),
                                        ]
                                      : [
                                          _menuItem('replace', '보강'),
                                          _menuItem('skip', '휴강'),
                                        ],
                           );
                           if (selected == null) return;
                           if (isReplacement) {
                             if (selected == 'replacement_change') {
                               await _showChangeReplacementDialog(s);
                             } else if (selected == 'replacement_cancel') {
                               await _confirmAndCancelReplacement(s);
                             }
                             // UI 즉시 반영
                             await Future.delayed(const Duration(milliseconds: 10));
                             if (mounted) {
                               setState(() {});
                               setLocalState(() {});
                             }
                             return;
                           }
                            if (isGhost && _hasSkipOverrideFor(s)) {
                              if (selected == 'skip_cancel') {
                                await _confirmAndCancelSkip(s);
                              }
                              await Future.delayed(const Duration(milliseconds: 10));
                              if (mounted) {
                                setState(() {});
                                setLocalState(() {});
                              }
                              return;
                            } else if (selected == 'replace') {
                             final isPast = s.dateTime.isBefore(now);
                             final hasAttendance = s.attendanceStatus == AttendanceStatus.arrived || s.attendanceStatus == AttendanceStatus.completed;
                             if (isPast && hasAttendance) {
                               await _showInfoDialog('이미 지난 수업이며 출석이 기록된 회차는 보강을 생성할 수 없습니다.');
                               return;
                             }
                              if (widget.onReplaceSelected != null) {
                                // 리스트 다이얼로그를 먼저 닫고 외부 콜백 호출
                                Navigator.of(context).pop();
                                await widget.onReplaceSelected!(s);
                              } else {
                                await _showReplaceDialog(s);
                              }
                           } else if (selected == 'skip') {
                             await _applySkipOverride(s);
                           }
                           // UI 즉시 반영
                           await Future.delayed(const Duration(milliseconds: 10));
                           if (mounted) {
                             setState(() {});
                             setLocalState(() {});
                           }
                         },
                         child: Container(
                        height: itemHeight,
                        decoration: isGhost
                            ? BoxDecoration(
                                color: const Color(0xFF1F1F1F), // 다이얼로그 배경색과 일치
                                borderRadius: BorderRadius.circular(8),
                              )
                            : null,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        dateStr,
                                        style: TextStyle(
                                          color: isGhost ? Colors.white70 : Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                      if (isReplacement) ...[
                                        const SizedBox(width: 8),
                                        _buildSmallBadge('보강', const Color(0xFF1976D2)),
                                      ] else if (isGhost && _hasSkipOverrideFor(s)) ...[
                                        const SizedBox(width: 8),
                                        _buildSmallBadge('휴강', Colors.black),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '주차: ${displayWeekNumber ?? '-'}  ·  ${displayWeeklyOrder ?? '-'}  ·  ${s.className}',
                                          style: TextStyle(color: isGhost ? Colors.white60 : Colors.white70, fontSize: 15),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            InkWell(
                              onTap: () async {
                                await _handleAttendanceClick(s);
                                // 부모 상태 갱신으로 세션 재계산
                                await Future.delayed(const Duration(milliseconds: 10));
                                if (mounted) {
                                  setState(() {});
                                  setLocalState(() {});
                                }
                              },
                              child: _buildStatusPill(s.attendanceStatus),
                            ),
                          ],
                        ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기', style: TextStyle(color: Colors.white70)),
                ),
              ],
            );
          },
        );
      },
    );
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
  
  // 미래 출석 카드가 생성 가능한지 확인 (실제 페이지 수 기준)
  bool _checkHasFutureCards() {
    if (widget.selectedStudent == null) return false;
    
    final studentId = widget.selectedStudent!.student.id;
    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList();
    
    if (timeBlocks.isEmpty) return false;
    
    // 등록일 확인
    final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
    if (registrationDate == null) return false;
    
    // 다음 페이지에서 실제로 생성될 세션 개수 계산
    final today = DateTime.now();
    final nextPageAdjustedToday = today.subtract(Duration(days: (widget.pageIndex + 1) * 91));
    final nextPageActualStartDate = nextPageAdjustedToday.isAfter(registrationDate) 
        ? nextPageAdjustedToday 
        : registrationDate;
    final nextPageEndDate = DateTime(
      nextPageActualStartDate.year,
      nextPageActualStartDate.month + 2,
      nextPageActualStartDate.day,
    );
    
    // 다음 페이지에서 생성될 수업이 있는지 간단히 확인
    if (nextPageActualStartDate.isAfter(nextPageEndDate) || 
        nextPageActualStartDate.isBefore(registrationDate)) {
      return false;
    }
    
    // 현재 _classSessions이 있다면 총 세션 수를 기준으로 페이지 계산
    if (_classSessions.isNotEmpty) {
      // 현재 표시 중인 데이터를 기준으로 추정
      // 실제로는 다음 페이지 데이터를 생성해서 확인해야 하지만, 
      // 성능상 간단한 추정 로직 사용
      return widget.pageIndex < 3; // 최대 4페이지 정도로 제한
    }
    
    return widget.pageIndex < 2; // 기본적으로 3페이지까지
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
    print('[DEBUG][AttendanceCheckView] _loadClassSessions 시작');
    print('[DEBUG][AttendanceCheckView] pageIndex: ${widget.pageIndex}');
    print('[DEBUG][AttendanceCheckView] selectedStudent: ${widget.selectedStudent?.student.name}');
    
    if (widget.selectedStudent == null) {
      setState(() {
        _classSessions = [];
      });
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // 페이지 인덱스에 따라 기간 계산
    // pageIndex = 0: 현재 기준 (과거 + 현재 + 오늘부터 +2달)
    // pageIndex > 0: 과거 기록만 (13주씩 뒤로)
    final adjustedToday = widget.pageIndex == 0 ? today : today.subtract(Duration(days: widget.pageIndex * 91));
    
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

    // 페이지별 세션 생성 로직
    final allSessions = <ClassSession>[];
    
    print('[DEBUG][AttendanceCheckView] adjustedToday: $adjustedToday');
    print('[DEBUG][AttendanceCheckView] today: $today');
    print('[DEBUG][AttendanceCheckView] registrationDate: $registrationDate');
    
    if (widget.pageIndex == 0) {
      // 현재 페이지: 과거 기록(오늘 이전) + 오늘부터 +2달까지 미래 수업
      print('[DEBUG][AttendanceCheckView] 현재 페이지 세션 생성');
      
      // 과거 기록: 오늘 이전의 실제 출석 기록만 불러옴
    final pastSessions = _loadPastSessionsFromDB(studentId, registrationDate, today);
      
      // 미래 세션: 오늘부터 +2달까지 생성 (등록일과 무관하게 오늘 기준)
      final futureSessions = _generateFutureSessionsFromToday(timeBlocks, today, now);
      
      print('[DEBUG][AttendanceCheckView] pastSessions count: ${pastSessions.length}');
      print('[DEBUG][AttendanceCheckView] futureSessions count: ${futureSessions.length}');
    allSessions.addAll(pastSessions);
    allSessions.addAll(futureSessions);
    } else {
      // 과거 페이지: adjustedToday 기준으로 과거 기록 + 미래 예정 수업 (2달치)
      print('[DEBUG][AttendanceCheckView] 과거 페이지 세션 생성');
      final rangeStart = adjustedToday.subtract(const Duration(days: 91)); // 13주 전
      final pastSessions = _loadPastSessionsFromDBRange(studentId, registrationDate, rangeStart, adjustedToday);
      final futureSessions = _generateFutureSessionsFromDate(timeBlocks, adjustedToday, now);
      print('[DEBUG][AttendanceCheckView] pastSessions count (${rangeStart} ~ ${adjustedToday}): ${pastSessions.length}');
      print('[DEBUG][AttendanceCheckView] futureSessions count (from ${adjustedToday}): ${futureSessions.length}');
      allSessions.addAll(pastSessions);
      allSessions.addAll(futureSessions);
    }

    // 날짜순 정렬
    allSessions.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    print('[DEBUG][AttendanceCheckView] allSessions total count: ${allSessions.length}');
    
    if (widget.pageIndex == 0) {
      // 현재 페이지: 스마트 슬라이딩 로직 적용
      _setupSmartSliding(allSessions, today);
    } else {
      // 과거 페이지: 기존 로직 유지  
      _applySessionSelection(allSessions, adjustedToday);
      
      // 화살표 활성화 상태 업데이트
      final newHasPastRecords = _checkHasPastRecords();
      final newHasFutureCards = _checkHasFutureCards();
      
      print('[DEBUG][AttendanceCheckView] newHasPastRecords: $newHasPastRecords');
      print('[DEBUG][AttendanceCheckView] newHasFutureCards: $newHasFutureCards');
      
      if (_hasPastRecords != newHasPastRecords || _hasFutureCards != newHasFutureCards) {
        setState(() {
          _hasPastRecords = newHasPastRecords;
          _hasFutureCards = newHasFutureCards;
        });
      }
    }
    
    print('[DEBUG][AttendanceCheckView] final _classSessions count: ${_classSessions.length}');
  }

  // 🎯 스마트 슬라이딩 초기 설정
  void _setupSmartSliding(List<ClassSession> allSessions, DateTime today) {
    final studentName = widget.selectedStudent?.student.name ?? "미선택";
    print('\n=== [SMART_SLIDING_DEBUG] 학생: $studentName ===');
    print('[DEBUG][_setupSmartSliding] 시작 - allSessions: ${allSessions.length}개');
    print('[DEBUG][_setupSmartSliding] today: $today');
    
    // 전체 세션 저장
    _allSessions = allSessions;
    
    // 전체 세션 날짜 로그
    print('[DEBUG][_setupSmartSliding] 전체 세션 목록:');
    for (int i = 0; i < allSessions.length; i++) {
      final session = allSessions[i];
      final sessionDate = DateTime(session.dateTime.year, session.dateTime.month, session.dateTime.day);
      final isSameAsToday = sessionDate.isAtSameMomentAs(today);
      final isAfterToday = sessionDate.isAfter(today);
      final isBeforeToday = sessionDate.isBefore(today);
      print('  [$i] ${session.dateTime} (${session.className}) - 오늘대비: ${isSameAsToday ? "오늘" : isAfterToday ? "미래" : "과거"}');
    }
    
    // 파란 테두리(오늘)의 절대 인덱스 찾기
    _blueBorderAbsoluteIndex = -1;
    for (int i = 0; i < allSessions.length; i++) {
      final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
      if (sessionDate.isAtSameMomentAs(today)) {
        _blueBorderAbsoluteIndex = i;
        print('[DEBUG][_setupSmartSliding] 오늘 수업 발견 - 인덱스: $i, 날짜: $sessionDate');
        break;
      }
    }
    
    // 오늘 수업이 없으면 가장 가까운 미래/과거 수업 찾기
    if (_blueBorderAbsoluteIndex == -1) {
      print('[DEBUG][_setupSmartSliding] 오늘 수업 없음 - 가장 가까운 수업 찾기');
      
      // 가장 가까운 미래 수업 찾기
      for (int i = 0; i < allSessions.length; i++) {
        final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
        if (sessionDate.isAfter(today)) {
          _blueBorderAbsoluteIndex = i;
          print('[DEBUG][_setupSmartSliding] 가장 가까운 미래 수업 - 인덱스: $i, 날짜: $sessionDate');
          break;
        }
      }
      
      // 미래 수업도 없으면 가장 최근 과거 수업 찾기
      if (_blueBorderAbsoluteIndex == -1) {
        for (int i = allSessions.length - 1; i >= 0; i--) {
          final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
          if (sessionDate.isBefore(today)) {
            _blueBorderAbsoluteIndex = i;
            print('[DEBUG][_setupSmartSliding] 가장 최근 과거 수업 - 인덱스: $i, 날짜: $sessionDate');
            break;
          }
        }
      }
    }
    
    print('[DEBUG][_setupSmartSliding] 최종 _blueBorderAbsoluteIndex: $_blueBorderAbsoluteIndex');
    
    // 초기 화면 설정 (파란 테두리를 가운데에)
    _setInitialView();
    
    // 화살표 활성화 상태 업데이트
    _updateNavigationState();
    
    print('=== [SMART_SLIDING_DEBUG] 학생: $studentName 완료 ===\n');
  }

  // 📍 초기 화면 설정 (파란 테두리를 가운데에)
  void _setInitialView() {
    final studentName = widget.selectedStudent?.student.name ?? "미선택";
    print('\n--- [SET_INITIAL_VIEW_DEBUG] 학생: $studentName ---');
    
    if (_allSessions.isEmpty || _blueBorderAbsoluteIndex == -1) {
      print('[DEBUG][_setInitialView] 세션이 없거나 파란테두리 없음 - 빈 화면');
      setState(() {
        _classSessions = [];
        _centerIndex = -1;
        _currentStartIndex = 0;
      });
      return;
    }
    
    print('[DEBUG][_setInitialView] 초기 화면 설정 시작:');
    print('  _allSessions.length: ${_allSessions.length}');
    print('  _blueBorderAbsoluteIndex: $_blueBorderAbsoluteIndex');
    
    // 파란 테두리를 가운데(_halfCenter) 인덱스에 배치하도록 계산
    if (_blueBorderAbsoluteIndex >= _halfCenter && _blueBorderAbsoluteIndex < _allSessions.length - _halfCenter) {
      // 완벽한 센터링 가능
      _currentStartIndex = _blueBorderAbsoluteIndex - _halfCenter;
      print('[DEBUG][_setInitialView] 완벽한 센터링 - startIndex: $_currentStartIndex (파란테두리를 가운데에)');
    } else if (_blueBorderAbsoluteIndex < _halfCenter) {
      // 과거 부족
      _currentStartIndex = 0;
      print('[DEBUG][_setInitialView] 과거 부족 - startIndex: $_currentStartIndex (처음부터 시작)');
    } else {
      // 미래 부족
      _currentStartIndex = (_allSessions.length - _visibleCount).clamp(0, _allSessions.length);
      print('[DEBUG][_setInitialView] 미래 부족 - startIndex: $_currentStartIndex (끝에서 $_visibleCount개)');
    }
    
    print('[DEBUG][_setInitialView] 최종 _currentStartIndex: $_currentStartIndex');
    print('--- [SET_INITIAL_VIEW_DEBUG] 설정 완료, 화면 업데이트 시작 ---');
    
    _updateDisplayedSessions();
  }

  // 📱 화면에 표시할 세션들 업데이트
  void _updateDisplayedSessions() {
    if (!mounted) return;
    
    final studentName = widget.selectedStudent?.student.name ?? "미선택";
    print('\n--- [UPDATE_DISPLAY_DEBUG] 학생: $studentName ---');
    
    final endIndex = (_currentStartIndex + _visibleCount).clamp(0, _allSessions.length);
    final displayedSessions = _allSessions.sublist(_currentStartIndex, endIndex);
    
    print('[DEBUG][_updateDisplayedSessions] 화면 업데이트:');
    print('  _currentStartIndex: $_currentStartIndex');
    print('  endIndex: ${endIndex - 1}');
    print('  표시할 세션 수: ${displayedSessions.length}개');
    print('  _blueBorderAbsoluteIndex: $_blueBorderAbsoluteIndex (고정값)');
    
    // 파란 테두리의 상대적 위치 계산 (절대 인덱스는 변경하지 않음!)
    int centerIndex = -1;
    if (_blueBorderAbsoluteIndex >= _currentStartIndex && _blueBorderAbsoluteIndex < endIndex) {
      centerIndex = _blueBorderAbsoluteIndex - _currentStartIndex;
      print('[DEBUG][_updateDisplayedSessions] 파란테두리 화면 내 위치: $centerIndex번째 (절대인덱스 $_blueBorderAbsoluteIndex)');
      
      // 파란 테두리 세션 정보 출력
      if (_blueBorderAbsoluteIndex < _allSessions.length) {
        final blueSession = _allSessions[_blueBorderAbsoluteIndex];
        print('[DEBUG][_updateDisplayedSessions] 파란테두리 세션: ${blueSession.dateTime} (${blueSession.className})');
      }
    } else {
      print('[DEBUG][_updateDisplayedSessions] 파란테두리 화면 밖 (절대인덱스 $_blueBorderAbsoluteIndex 유지)');
    }
    
    // 화면에 표시되는 세션들 로그
    print('[DEBUG][_updateDisplayedSessions] 표시 세션 목록:');
    for (int i = 0; i < displayedSessions.length; i++) {
      final session = displayedSessions[i];
      final absoluteIndex = _currentStartIndex + i;
      final isBlueCard = (absoluteIndex == _blueBorderAbsoluteIndex);
      print('  [상대$i/절대$absoluteIndex] ${session.dateTime} (${session.className}) ${isBlueCard ? "★파란카드★" : ""}');
    }
    
    if (mounted) {
      setState(() {
        _classSessions = displayedSessions;
        _centerIndex = centerIndex;
      });
    }
    
    print('--- [UPDATE_DISPLAY_DEBUG] 완료 ---\n');
  }

  // 🔄 네비게이션 상태 업데이트
  void _updateNavigationState() {
    if (!mounted) return;
    
    final newHasPastRecords = _currentStartIndex > 0;
    final newHasFutureCards = _currentStartIndex + _visibleCount < _allSessions.length;
    
    print('[DEBUG][_updateNavigationState] hasPast: $newHasPastRecords, hasFuture: $newHasFutureCards');
    
    if (mounted && (_hasPastRecords != newHasPastRecords || _hasFutureCards != newHasFutureCards)) {
      setState(() {
        _hasPastRecords = newHasPastRecords;
        _hasFutureCards = newHasFutureCards;
      });
    }
  }

  // ⬅️ 왼쪽으로 이동 (과거)
  void _moveLeft() {
    final studentName = widget.selectedStudent?.student.name ?? "미선택";
    print('\n--- [MOVE_LEFT_DEBUG] 학생: $studentName ---');
    print('[DEBUG][_moveLeft] 이동 전 상태:');
    print('  _currentStartIndex: $_currentStartIndex');
    print('  _blueBorderAbsoluteIndex: $_blueBorderAbsoluteIndex');
    print('  _allSessions.length: ${_allSessions.length}');
    
    if (_currentStartIndex <= 0) {
      print('[DEBUG][_moveLeft] 이동 불가 - 이미 시작점');
      return;
    }
    
    final leftCards = _currentStartIndex;
    print('[DEBUG][_moveLeft] 왼쪽 카드 수: $leftCards개');
    
    if (leftCards >= _visibleCount) {
      // 화면당 개수만큼 점프
      final oldStartIndex = _currentStartIndex;
      _currentStartIndex = (_currentStartIndex - _visibleCount).clamp(0, _allSessions.length);
      print('[DEBUG][_moveLeft] $_visibleCount칸 점프 - $oldStartIndex → $_currentStartIndex');
    } else {
      // 1칸씩 슬라이딩
      final oldStartIndex = _currentStartIndex;
      _currentStartIndex = (_currentStartIndex - 1).clamp(0, _allSessions.length);
      print('[DEBUG][_moveLeft] 1칸 슬라이딩 - $oldStartIndex → $_currentStartIndex');
    }
    
    print('[DEBUG][_moveLeft] 이동 후 상태:');
    print('  새 _currentStartIndex: $_currentStartIndex');
    print('  파란테두리는 절대인덱스 $_blueBorderAbsoluteIndex 그대로 유지');
    
    _updateDisplayedSessions();
    _updateNavigationState();
    
    print('--- [MOVE_LEFT_DEBUG] 완료 ---\n');
  }

  // ➡️ 오른쪽으로 이동 (미래)
  void _moveRight() {
    final studentName = widget.selectedStudent?.student.name ?? "미선택";
    print('\n--- [MOVE_RIGHT_DEBUG] 학생: $studentName ---');
    print('[DEBUG][_moveRight] 이동 전 상태:');
    print('  _currentStartIndex: $_currentStartIndex');
    print('  _blueBorderAbsoluteIndex: $_blueBorderAbsoluteIndex');
    print('  _allSessions.length: ${_allSessions.length}');
    
    if (_currentStartIndex + _visibleCount >= _allSessions.length) {
      print('[DEBUG][_moveRight] 이동 불가 - 이미 끝점');
      return;
    }
    
    // 점프 후에도 완전한 화면을 만들 수 있는지 확인
    final jumpTargetStartIndex = _currentStartIndex + _visibleCount;
    final canMakeFullAfterJump = (jumpTargetStartIndex + _visibleCount) <= _allSessions.length;
    
    print('[DEBUG][_moveRight] $_visibleCount칸 점프 가능성 분석:');
    print('  현재 시작: $_currentStartIndex');
    print('  13칸 점프 목표: $jumpTargetStartIndex');
    print('  점프 후 화면 끝: ${jumpTargetStartIndex + _visibleCount}');
    print('  전체 세션 수: ${_allSessions.length}');
    print('  점프 후 완전한 화면 가능: $canMakeFullAfterJump');
    
    if (canMakeFullAfterJump) {
      // 화면당 개수만큼 점프 (점프 후에도 완전한 화면 가능)
      final oldStartIndex = _currentStartIndex;
      _currentStartIndex = jumpTargetStartIndex;
      print('[DEBUG][_moveRight] $_visibleCount칸 점프 - $oldStartIndex → $_currentStartIndex');
    } else {
      // 1칸씩 슬라이딩 (점프하면 마지막이 안 채워짐)
      final oldStartIndex = _currentStartIndex;
      _currentStartIndex = (_currentStartIndex + 1).clamp(0, _allSessions.length - _visibleCount);
      print('[DEBUG][_moveRight] 1칸 슬라이딩 - $oldStartIndex → $_currentStartIndex (점프하면 화면이 안 채워짐)');
    }
    
    print('[DEBUG][_moveRight] 이동 후 상태:');
    print('  새 _currentStartIndex: $_currentStartIndex');
    print('  파란테두리는 절대인덱스 $_blueBorderAbsoluteIndex 그대로 유지');
    
    _updateDisplayedSessions();
    _updateNavigationState();
    
    print('--- [MOVE_RIGHT_DEBUG] 완료 ---\n');
  }

  // 🗄️ 과거 출석 기록에서 ClassSession 생성 (set_id별로 그룹화)
  List<ClassSession> _loadPastSessionsFromDB(String studentId, DateTime registrationDate, DateTime today) {
    print('[DEBUG][_loadPastSessionsFromDB] studentId: $studentId, registrationDate: $registrationDate, today: $today');
    final pastSessions = <ClassSession>[];
    
    // DB에서 해당 학생의 모든 출석 기록 조회
    final attendanceRecords = DataManager.instance.attendanceRecords
        .where((record) => record.studentId == studentId)
        .where((record) {
          final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
          return recordDate.isBefore(today) && !recordDate.isBefore(registrationDate);
        })
        .toList();
    
    print('[DEBUG][_loadPastSessionsFromDB] 전체 attendanceRecords 개수: ${DataManager.instance.attendanceRecords.length}');
    print('[DEBUG][_loadPastSessionsFromDB] 필터링된 attendanceRecords 개수: ${attendanceRecords.length}');

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

      final weeklyOrder = _getWeeklyOrderForSet(extractedSetId, DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList());
      final session = ClassSession(
        dateTime: startTime,
        className: firstRecord.className,
        dayOfWeek: _getDayOfWeekFromDate(startTime),
        duration: endTime.difference(startTime).inMinutes,
        setId: extractedSetId,
        weeklyOrder: weeklyOrder,
        weekNumber: _computeWeekNumber(registrationDate, startTime),
        isAttended: isAttended,
        arrivalTime: earliestArrival,
        departureTime: latestDeparture,
        attendanceStatus: _getAttendanceStatusFromRecords(records),
      );
      pastSessions.add(session);
    }

    return pastSessions;
  }

  // 🗄️ 특정 범위의 과거 출석 기록에서 ClassSession 생성
  List<ClassSession> _loadPastSessionsFromDBRange(String studentId, DateTime registrationDate, DateTime rangeStart, DateTime rangeEnd) {
    print('[DEBUG][_loadPastSessionsFromDBRange] studentId: $studentId, rangeStart: $rangeStart, rangeEnd: $rangeEnd');
    final pastSessions = <ClassSession>[];
    
    // DB에서 해당 학생의 특정 범위 출석 기록 조회
    final attendanceRecords = DataManager.instance.attendanceRecords
        .where((record) => record.studentId == studentId)
        .where((record) {
          final recordDate = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
          return recordDate.isAfter(rangeStart) && 
                 recordDate.isBefore(rangeEnd) && 
                 !recordDate.isBefore(registrationDate);
        })
        .toList();
    
    print('[DEBUG][_loadPastSessionsFromDBRange] 필터링된 attendanceRecords 개수: ${attendanceRecords.length}');

    // 🔄 날짜별, 수업명별로 출석 기록을 그룹화
    final Map<String, List<AttendanceRecord>> groupedRecords = {};
    
    for (final record in attendanceRecords) {
      final dateKey = '${record.classDateTime.year}-${record.classDateTime.month}-${record.classDateTime.day}';
      final className = record.className;
      final key = '$dateKey-$className';
      
      groupedRecords.putIfAbsent(key, () => []).add(record);
    }

    // 각 그룹에서 대표 ClassSession 생성
    for (final entry in groupedRecords.entries) {
      final records = entry.value;
      if (records.isEmpty) continue;

      final firstRecord = records.first;
      final classDateTime = firstRecord.classDateTime;

      // 해당 날짜/setId의 모든 기록에서 가장 이른 등원시간과 가장 늦은 하원시간 찾기
      DateTime? earliestArrival;
      DateTime? latestDeparture;

      for (final record in records) {
        if (record.arrivalTime != null) {
          if (earliestArrival == null || record.arrivalTime!.isBefore(earliestArrival)) {
            earliestArrival = record.arrivalTime;
          }
        }
        if (record.departureTime != null) {
          if (latestDeparture == null || record.departureTime!.isAfter(latestDeparture)) {
            latestDeparture = record.departureTime;
          }
        }
      }

      final session = ClassSession(
        dateTime: classDateTime,
        className: firstRecord.className,
        dayOfWeek: _getDayOfWeekFromDate(classDateTime),
        duration: 50, // 기본값
        setId: null, // AttendanceRecord에는 setId가 없으므로 null
        weeklyOrder: null,
        weekNumber: _computeWeekNumber(registrationDate, classDateTime),
        isAttended: firstRecord.isPresent,
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
    // 미래 세션 생성 범위 제한
    // pageIndex = 0: 오늘부터 +2달 (약 60일)
    // pageIndex > 0: 과거 기록만 (미래 세션 생성 안 함)
    final endDate = widget.pageIndex == 0 
        ? DateTime(today.year, today.month + 2, today.day) // 정확한 2달
        : today; // 과거 페이지에서는 미래 세션 생성 안 함
    
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

        final registrationDate = widget.selectedStudent!.basicInfo.registrationDate ?? today;
        final session = ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekFromDate(classDateTime),
          duration: totalDurationMinutes,
          setId: entry.key, // setId 포함
          weeklyOrder: firstBlock.weeklyOrder,
          weekNumber: _computeWeekNumber(registrationDate, classDateTime),
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

  // 🔮 오늘부터 2달까지 미래 수업 세션 생성 (등록일 무관)
  List<ClassSession> _generateFutureSessionsFromToday(List<StudentTimeBlock> timeBlocks, DateTime today, DateTime now) {
    print('[DEBUG][_generateFutureSessionsFromToday] today: $today');
    final futureSessions = <ClassSession>[];
    
    // SET_ID별로 timeBlocks 그룹화
    final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
    for (final block in timeBlocks) {
      blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
    }
    
    print('[DEBUG][_generateFutureSessionsFromToday] timeBlocks 총 개수: ${timeBlocks.length}');
    print('[DEBUG][_generateFutureSessionsFromToday] setId별 그룹 개수: ${blocksBySetId.length}');
    
    // 오늘부터 +2달까지 미래 수업 생성
    final endDate = DateTime(today.year, today.month + 2, today.day);
    print('[DEBUG][_generateFutureSessionsFromToday] endDate: $endDate');
    
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
      
      print('[DEBUG][_generateFutureSessionsFromToday] setId: ${entry.key}, dayIndex: $dayIndex');
      
      int generatedCount = 0;
      // 오늘부터 해당 요일에 수업 생성
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

        // 기존 출석 기록 확인
        final attendanceRecord = DataManager.instance.getAttendanceRecord(
          widget.selectedStudent!.student.id,
          classDateTime,
        );

        // 전체 수업 시간 계산
        final startMinutes = firstBlock.startHour * 60 + firstBlock.startMinute;
        final lastBlockEndMinutes = lastBlock.startHour * 60 + lastBlock.startMinute + lastBlock.duration.inMinutes;
        final totalDurationMinutes = lastBlockEndMinutes - startMinutes;

        final registrationDate = widget.selectedStudent!.basicInfo.registrationDate ?? today;
        final session = ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekFromDate(classDateTime),
          duration: totalDurationMinutes,
          setId: entry.key,
          weeklyOrder: firstBlock.weeklyOrder,
          weekNumber: _computeWeekNumber(registrationDate, classDateTime),
          isAttended: attendanceRecord?.isPresent ?? false,
          arrivalTime: attendanceRecord?.arrivalTime,
          departureTime: attendanceRecord?.departureTime,
          attendanceStatus: _getAttendanceStatus(attendanceRecord),
        );

        futureSessions.add(session);
        generatedCount++;
      }
      
      print('[DEBUG][_generateFutureSessionsFromToday] setId ${entry.key} 총 생성 개수: $generatedCount');
    }

    // 오버라이드 적용 (skip/replace/add)
    final studentId = widget.selectedStudent!.student.id;
    _applyOverridesToFutureSessions(
      studentId: studentId,
      sessions: futureSessions,
      timeBlocks: timeBlocks,
      rangeStart: today,
      rangeEnd: DateTime(today.year, today.month + 2, today.day),
    );

    return futureSessions;
  }

  // 🔮 특정 날짜부터 미래 수업 세션 생성 (등록일 이후만)
  List<ClassSession> _generateFutureSessionsFromDate(List<StudentTimeBlock> timeBlocks, DateTime startDate, DateTime now) {
    print('[DEBUG][_generateFutureSessionsFromDate] startDate: $startDate');
    final futureSessions = <ClassSession>[];
    
    // 등록일 확인
    final registrationDate = widget.selectedStudent?.basicInfo.registrationDate;
    if (registrationDate == null) {
      print('[DEBUG][_generateFutureSessionsFromDate] registrationDate가 null - 수업 생성하지 않음');
      return futureSessions;
    }
    
    // startDate와 registrationDate 중 더 늦은 날짜를 실제 시작일로 사용
    final actualStartDate = startDate.isAfter(registrationDate) ? startDate : registrationDate;
    print('[DEBUG][_generateFutureSessionsFromDate] actualStartDate: $actualStartDate (registrationDate: $registrationDate)');
    
    // SET_ID별로 timeBlocks 그룹화
    final Map<String?, List<StudentTimeBlock>> blocksBySetId = {};
    for (final block in timeBlocks) {
      blocksBySetId.putIfAbsent(block.setId, () => []).add(block);
    }
    
    print('[DEBUG][_generateFutureSessionsFromDate] timeBlocks 총 개수: ${timeBlocks.length}');
    print('[DEBUG][_generateFutureSessionsFromDate] setId별 그룹 개수: ${blocksBySetId.length}');
    for (final entry in blocksBySetId.entries) {
      final blocks = entry.value;
      if (blocks.isNotEmpty) {
        final firstBlock = blocks.first;
        print('[DEBUG][_generateFutureSessionsFromDate] setId: ${entry.key}, 요일: ${firstBlock.dayIndex}, 시간: ${firstBlock.startHour}:${firstBlock.startMinute}');
      }
    }
    
    // actualStartDate부터 +2달까지 미래 수업 생성 (정확한 월 계산)
    final endDate = DateTime(
      actualStartDate.year,
      actualStartDate.month + 2,
      actualStartDate.day,
    );
    print('[DEBUG][_generateFutureSessionsFromDate] endDate: $endDate');
    
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
      
      // 해당 요일에만 수업 생성 (등록일 이후부터)
      print('[DEBUG][_generateFutureSessionsFromDate] setId: ${entry.key}, dayIndex: $dayIndex');
      
      int generatedCount = 0;
      for (DateTime date = actualStartDate; date.isBefore(endDate); date = date.add(const Duration(days: 1))) {
        // 해당 날짜가 이 setId의 수업 요일인지 확인
        if (date.weekday - 1 != dayIndex) continue;
        
        print('[DEBUG][_generateFutureSessionsFromDate] 수업 생성 중 - 날짜: $date, 요일: ${date.weekday - 1}');
        
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
          classDateTime,
        );

        // 전체 수업 시간 계산
        final startMinutes = firstBlock.startHour * 60 + firstBlock.startMinute;
        final lastBlockEndMinutes = lastBlock.startHour * 60 + lastBlock.startMinute + lastBlock.duration.inMinutes;
        final totalDurationMinutes = lastBlockEndMinutes - startMinutes;

        final session = ClassSession(
          dateTime: classDateTime,
          className: className,
          dayOfWeek: _getDayOfWeekFromDate(classDateTime),
          duration: totalDurationMinutes,
          setId: entry.key,
          weeklyOrder: firstBlock.weeklyOrder,
          weekNumber: _computeWeekNumber(registrationDate, classDateTime),
          isAttended: attendanceRecord?.isPresent ?? false,
          arrivalTime: attendanceRecord?.arrivalTime,
          departureTime: attendanceRecord?.departureTime,
          attendanceStatus: _getAttendanceStatus(attendanceRecord),
        );

        futureSessions.add(session);
        generatedCount++;
        print('[DEBUG][_generateFutureSessionsFromDate] 세션 생성 완료 - ${classDateTime}, className: $className');
      }
      
      print('[DEBUG][_generateFutureSessionsFromDate] setId ${entry.key} 총 생성 개수: $generatedCount');
    }

    // 오버라이드 적용 (skip/replace/add)
    final studentId = widget.selectedStudent!.student.id;
    _applyOverridesToFutureSessions(
      studentId: studentId,
      sessions: futureSessions,
      timeBlocks: timeBlocks,
      rangeStart: actualStartDate,
      rangeEnd: endDate,
    );

    return futureSessions;
  }

  // === 오버라이드 적용 유틸 ===
  void _applyOverridesToFutureSessions({
    required String studentId,
    required List<ClassSession> sessions,
    required List<StudentTimeBlock> timeBlocks,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) {
    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour && a.minute == b.minute;

    // 빠른 조회용 맵 (dateTime -> index)
    int indexOfDate(DateTime dt) {
      for (int i = 0; i < sessions.length; i++) {
        if (sameMinute(sessions[i].dateTime, dt)) return i;
      }
      return -1;
    }

    int _inferDefaultDurationMinutes() {
      if (timeBlocks.isEmpty) return DataManager.instance.academySettings.lessonDuration;
      // 같은 setId 내의 첫/마지막 블록을 통해 총합 추정
      final Map<String?, List<StudentTimeBlock>> bySet = {};
      for (final b in timeBlocks) {
        bySet.putIfAbsent(b.setId, () => []).add(b);
      }
      for (final entry in bySet.entries) {
        if (entry.value.isEmpty) continue;
        entry.value.sort((a, b) => (a.startHour * 60 + a.startMinute).compareTo(b.startHour * 60 + b.startMinute));
        final first = entry.value.first;
        final last = entry.value.last;
        final start = first.startHour * 60 + first.startMinute;
        final end = last.startHour * 60 + last.startMinute + last.duration.inMinutes;
        final total = end - start;
        if (total > 0) return total;
      }
      return DataManager.instance.academySettings.lessonDuration;
    }

    int? _inferWeeklyOrderFromOriginal(DateTime? originalDateTime) {
      if (originalDateTime == null) return null;
      final blocks = DataManager.instance.studentTimeBlocks
          .where((b) => b.studentId == studentId)
          .toList();
      if (blocks.isEmpty) return null;
      // setId별 대표 시간(시:분)과 weekly_order 매핑
      final Map<String, Map<String, int>> setIdToTimeAndOrder = {};
      for (final b in blocks) {
        if (b.setId == null) continue;
        setIdToTimeAndOrder.putIfAbsent(b.setId!, () => {
          'hour': b.startHour,
          'minute': b.startMinute,
          'order': b.weeklyOrder ?? 0,
        });
      }
      if (setIdToTimeAndOrder.isEmpty) return null;
      // original 시간과 가장 가까운 set 선택
      final targetMinutes = originalDateTime.hour * 60 + originalDateTime.minute;
      String? bestSetId;
      int bestDiff = 1 << 30;
      setIdToTimeAndOrder.forEach((setId, map) {
        final minutes = (map['hour']! * 60) + map['minute']!;
        final diff = (minutes - targetMinutes).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestSetId = setId;
        }
      });
      if (bestSetId == null) return null;
      return setIdToTimeAndOrder[bestSetId]!['order'];
    }

    String _inferClassName() {
      try {
        // 첫 블록의 sessionTypeId로 클래스명 추정
        final b = timeBlocks.firstWhere((e) => e.sessionTypeId != null);
        final classInfo = DataManager.instance.classes.firstWhere((c) => c.id == b.sessionTypeId);
        return classInfo.name;
      } catch (_) {
        return '수업';
      }
    }

    final overrides = DataManager.instance.getSessionOverridesForStudent(studentId);
    if (overrides.isEmpty) return;

    final defaultDuration = _inferDefaultDurationMinutes();
    final defaultClassName = _inferClassName();

    for (final ov in overrides) {
      // 취소된 보강/예외는 무시
      if (ov.status == OverrideStatus.canceled) {
        // ignore canceled overrides
        continue;
      }
      // 범위 밖은 무시
      bool inRange(DateTime dt) =>
          !dt.isBefore(rangeStart) && dt.isBefore(rangeEnd);

      if (ov.overrideType == OverrideType.skip || ov.overrideType == OverrideType.replace) {
        final bool hasOriginal = ov.originalClassDateTime != null && inRange(ov.originalClassDateTime!);
        int originalIdx = -1;
        ClassSession? originalSession;
        if (hasOriginal) {
          originalIdx = indexOfDate(ov.originalClassDateTime!);
          if (originalIdx != -1) {
            originalSession = sessions[originalIdx];
            if (ov.overrideType == OverrideType.replace) {
              // 원래 회차는 고스트로 남김
              sessions[originalIdx] = ClassSession(
                dateTime: originalSession.dateTime,
                className: originalSession.className,
                dayOfWeek: originalSession.dayOfWeek,
                duration: originalSession.duration,
                setId: originalSession.setId,
                weeklyOrder: originalSession.weeklyOrder,
                weekNumber: originalSession.weekNumber,
                isAttended: originalSession.isAttended,
                arrivalTime: originalSession.arrivalTime,
                departureTime: originalSession.departureTime,
                attendanceStatus: originalSession.attendanceStatus,
                isOverrideOriginalGhost: true,
                overrideOriginalDateTime: originalSession.overrideOriginalDateTime ?? originalSession.dateTime,
              );
            } else {
              // skip은 제거하지 않고 휴강 카드로 표시
              sessions[originalIdx] = ClassSession(
                dateTime: originalSession.dateTime,
                className: originalSession.className,
                dayOfWeek: originalSession.dayOfWeek,
                duration: originalSession.duration,
                setId: originalSession.setId,
                weeklyOrder: originalSession.weeklyOrder,
                weekNumber: originalSession.weekNumber,
                isAttended: false,
                arrivalTime: null,
                departureTime: null,
                attendanceStatus: AttendanceStatus.none,
                isOverrideOriginalGhost: true,
                overrideOriginalDateTime: originalSession.dateTime,
              );
              originalSession = sessions[originalIdx];
            }
          } else if (ov.overrideType == OverrideType.replace) {
            // 원래 세션이 생성되지 않았더라도 고스트 세션을 강제로 추가하여 보존
            final registrationDateGhost = widget.selectedStudent?.basicInfo.registrationDate;
            final ghostDuration = ov.durationMinutes ?? _inferDefaultDurationMinutes();
            final ghostWeeklyOrder = originalSession?.weeklyOrder
                ?? (ov.setId != null
                    ? _getWeeklyOrderForSet(ov.setId, DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList())
                    : _inferWeeklyOrderFromOriginal(ov.originalClassDateTime));
            final ghostWeekNumber = (registrationDateGhost != null && ov.originalClassDateTime != null)
                ? _computeWeekNumber(registrationDateGhost, ov.originalClassDateTime!)
                : null;
            final ghostClassName = _inferClassName();
            final ghost = ClassSession(
              dateTime: ov.originalClassDateTime!,
              className: ghostClassName,
              dayOfWeek: _getDayOfWeekFromDate(ov.originalClassDateTime!),
              duration: ghostDuration,
              setId: ov.setId,
              weeklyOrder: ghostWeeklyOrder,
              weekNumber: ghostWeekNumber,
              isAttended: false,
              arrivalTime: null,
              departureTime: null,
              attendanceStatus: AttendanceStatus.none,
              isOverrideOriginalGhost: true,
              overrideOriginalDateTime: ov.originalClassDateTime,
            );
            sessions.add(ghost);
          }
        }

        // replacement 처리: 원본이 화면에 없더라도 대체는 반드시 반영
        if (ov.overrideType == OverrideType.replace && ov.replacementClassDateTime != null && inRange(ov.replacementClassDateTime!)) {
          // 주간 시간표 변경으로 생성된 "해당 주차의 기본 세션"은 제거하여 보강이 있는 주차는 영향을 받지 않도록 한다
          final regDateForRemoval = widget.selectedStudent?.basicInfo.registrationDate;
          final int? targetWeeklyOrderForRemoval = originalSession?.weeklyOrder
              ?? (ov.setId != null
                  ? _getWeeklyOrderForSet(ov.setId, DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList())
                  : _inferWeeklyOrderFromOriginal(ov.originalClassDateTime));
          final int? targetWeekNumberForRemoval = (regDateForRemoval != null && ov.originalClassDateTime != null)
              ? _computeWeekNumber(regDateForRemoval, ov.originalClassDateTime!)
              : null;
          if (targetWeeklyOrderForRemoval != null && targetWeekNumberForRemoval != null) {
            sessions.removeWhere((s) =>
              s.weeklyOrder == targetWeeklyOrderForRemoval &&
              s.weekNumber == targetWeekNumberForRemoval &&
              !s.isOverrideReplacement &&
              !s.isOverrideOriginalGhost
            );
          }
          final int replacementIdx = indexOfDate(ov.replacementClassDateTime!);
          final attendanceRecord = DataManager.instance.getAttendanceRecord(studentId, ov.replacementClassDateTime!);
          // 루트 원본 앵커 계산
          final DateTime rootOriginalDateTime = (originalSession?.overrideOriginalDateTime ?? ov.originalClassDateTime) ?? ov.replacementClassDateTime!;

          if (replacementIdx != -1) {
            // 이미 생성된 기본 세션이 있으면 그것을 대체 세션으로 태깅
            final base = sessions[replacementIdx];
            sessions[replacementIdx] = ClassSession(
              dateTime: base.dateTime,
              className: base.className,
              dayOfWeek: base.dayOfWeek,
              duration: ov.durationMinutes ?? base.duration,
              setId: base.setId,
              weeklyOrder: originalSession?.weeklyOrder
                  ?? (ov.setId != null
                      ? _getWeeklyOrderForSet(ov.setId, DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList())
                      : _inferWeeklyOrderFromOriginal(ov.originalClassDateTime))
                  ?? base.weeklyOrder,
              weekNumber: originalSession?.weekNumber ?? base.weekNumber,
              isAttended: attendanceRecord?.isPresent ?? base.isAttended,
              arrivalTime: attendanceRecord?.arrivalTime ?? base.arrivalTime,
              departureTime: attendanceRecord?.departureTime ?? base.departureTime,
              attendanceStatus: _getAttendanceStatus(attendanceRecord) == AttendanceStatus.none ? base.attendanceStatus : _getAttendanceStatus(attendanceRecord),
              isOverrideReplacement: true,
              overrideOriginalDateTime: rootOriginalDateTime,
            );
          } else {
            // 없으면 새로 추가
            final classNameForNew = originalSession?.className ?? defaultClassName;
            final durationForNew = ov.durationMinutes ?? originalSession?.duration ?? defaultDuration;
            final int? replacementWeeklyOrder = originalSession?.weeklyOrder
                ?? (ov.setId != null
                    ? _getWeeklyOrderForSet(ov.setId, DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList())
                    : _inferWeeklyOrderFromOriginal(ov.originalClassDateTime));
            final newSession = ClassSession(
              dateTime: ov.replacementClassDateTime!,
              className: classNameForNew,
              dayOfWeek: _getDayOfWeekFromDate(ov.replacementClassDateTime!),
              duration: durationForNew,
              setId: originalSession?.setId ?? ov.setId,
              weeklyOrder: replacementWeeklyOrder,
              weekNumber: originalSession?.weekNumber,
              isAttended: attendanceRecord?.isPresent ?? false,
              arrivalTime: attendanceRecord?.arrivalTime,
              departureTime: attendanceRecord?.departureTime,
              attendanceStatus: _getAttendanceStatus(attendanceRecord),
              isOverrideReplacement: true,
              overrideOriginalDateTime: rootOriginalDateTime,
            );
            sessions.add(newSession);
          }
        }
      }

      if (ov.overrideType == OverrideType.add) {
        if (ov.replacementClassDateTime != null && inRange(ov.replacementClassDateTime!)) {
          // 중복 방지
          if (indexOfDate(ov.replacementClassDateTime!) == -1) {
            final attendanceRecord = DataManager.instance.getAttendanceRecord(studentId, ov.replacementClassDateTime!);
            final newSession = ClassSession(
              dateTime: ov.replacementClassDateTime!,
              className: '추가 수업',
              dayOfWeek: _getDayOfWeekFromDate(ov.replacementClassDateTime!),
              duration: ov.durationMinutes ?? defaultDuration,
              setId: null,
              weeklyOrder: null,
              weekNumber: null,
              isAttended: attendanceRecord?.isPresent ?? false,
              arrivalTime: attendanceRecord?.arrivalTime,
              departureTime: attendanceRecord?.departureTime,
              attendanceStatus: _getAttendanceStatus(attendanceRecord),
            );
            sessions.add(newSession);
          }
        }
      }
    }
  }

  // 📍 13개 세션 선택 및 가운데 인덱스 설정
  void _applySessionSelection(List<ClassSession> allSessions, DateTime today) {
    print('[DEBUG][_applySessionSelection] 시작 - allSessions count: ${allSessions.length}, pageIndex: ${widget.pageIndex}');
    print('[DEBUG][_applySessionSelection] today: $today');
    
    // 생성된 세션들의 날짜 범위 출력
    if (allSessions.isNotEmpty) {
      final firstSession = allSessions.first;
      final lastSession = allSessions.last;
      print('[DEBUG][_applySessionSelection] 세션 날짜 범위: ${firstSession.dateTime} ~ ${lastSession.dateTime}');
    }
    
    // 과거 기록을 보는 경우(pageIndex > 0) 파란 테두리 비활성화
    if (widget.pageIndex > 0) {
      // 과거 페이지에서도 13개씩 순차적 페이징
      final pageSize = 13;
      final totalPages = (allSessions.length / pageSize).ceil();
      final currentPageIndex = widget.pageIndex - 1; // pageIndex=1이 첫 번째 과거 페이지
      
      print('[DEBUG][_applySessionSelection] 과거 페이지 - 총 세션: ${allSessions.length}개, 총 페이지: $totalPages, 현재 페이지: $currentPageIndex');
      
      if (currentPageIndex >= totalPages) {
        // 페이지 범위를 벗어나면 빈 세션
        print('[DEBUG][_applySessionSelection] 페이지 범위 초과 - 빈 세션 표시');
        setState(() {
          _classSessions = [];
          _centerIndex = -1;
        });
        return;
      }
      
      final startIndex = currentPageIndex * pageSize;
      final endIndex = (startIndex + pageSize).clamp(0, allSessions.length);
      final selectedSessions = allSessions.sublist(startIndex, endIndex);
      
      print('[DEBUG][_applySessionSelection] 과거 페이지 - 선택된 세션: ${selectedSessions.length}개 (${startIndex}~${endIndex-1})');
      if (selectedSessions.isNotEmpty) {
        print('[DEBUG][_applySessionSelection] 세션 범위: ${selectedSessions.first.dateTime} ~ ${selectedSessions.last.dateTime}');
      }
      
      setState(() {
        _classSessions = selectedSessions;
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
    
    // 11개 수업만 선택 (가운데 수업 기준으로 앞뒤 5개씩)
    if (allSessions.length <= 11) {
      // 전체 수업이 13개 이하면 모두 표시하고 가운데 인덱스 조정
      final actualCenterIndex = centerIndex.clamp(0, allSessions.length - 1);
      setState(() {
        _classSessions = allSessions;
        _centerIndex = actualCenterIndex;
      });
      return;
    }
    
    // 현재 페이지에서도 스마트 페이징 적용
    // pageIndex == 0이면 기존 로직 (오늘 기준), pageIndex > 0이면 위에서 처리됨
    
    // 11개씩 점프하는 스마트 페이징
    final pageSize = 11;
    final totalPages = (allSessions.length / pageSize).ceil();
    
    print('[DEBUG][_applySessionSelection] 현재 페이지 - 총 세션: ${allSessions.length}개, 총 페이지: $totalPages');
    
    // 오늘 수업 또는 가장 가까운 미래 수업을 포함한 페이지 찾기
    int targetPageIndex = 0;
    int todayOrNextSessionIndex = -1;
    
    // 1. 먼저 오늘 수업이 있는지 확인
    for (int i = 0; i < allSessions.length; i++) {
      final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
      if (sessionDate.isAtSameMomentAs(today)) {
        todayOrNextSessionIndex = i;
        break;
      }
    }
    
    // 2. 오늘 수업이 없으면 가장 가까운 미래 수업 찾기
    if (todayOrNextSessionIndex == -1) {
      for (int i = 0; i < allSessions.length; i++) {
        final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
        if (sessionDate.isAfter(today)) {
          todayOrNextSessionIndex = i;
          break;
        }
      }
    }
    
    // 3. 미래 수업도 없으면 가장 최근 과거 수업 찾기
    if (todayOrNextSessionIndex == -1) {
      for (int i = allSessions.length - 1; i >= 0; i--) {
        final sessionDate = DateTime(allSessions[i].dateTime.year, allSessions[i].dateTime.month, allSessions[i].dateTime.day);
        if (sessionDate.isBefore(today) || sessionDate.isAtSameMomentAs(today)) {
          todayOrNextSessionIndex = i;
          break;
        }
      }
    }
    
    // 타겟 세션을 포함하는 페이지 계산
    if (todayOrNextSessionIndex >= 0) {
      targetPageIndex = (todayOrNextSessionIndex / pageSize).floor();
    }
    
    print('[DEBUG][_applySessionSelection] 타겟 세션 인덱스: $todayOrNextSessionIndex, 타겟 페이지: $targetPageIndex');
    
    // 스마트 센터링: 과거 기록이 충분하면 파란 테두리를 가운데(4번 인덱스)에 배치
    int startIndex;
    int actualCenterIndex = -1;
    
    if (allSessions.length <= 11) {
      // 전체 수업이 13개 이하면 모두 표시
      startIndex = 0;
      final selectedSessions = allSessions;
      if (todayOrNextSessionIndex >= 0) {
        actualCenterIndex = todayOrNextSessionIndex;
      }
      print('[DEBUG][_applySessionSelection] 13개 이하 - 전체 표시, centerIndex: $actualCenterIndex');
    } else {
      // 11개보다 많을 때: 파란 테두리를 가운데(5번 인덱스)에 배치하도록 계산
      if (todayOrNextSessionIndex >= 5 && todayOrNextSessionIndex < allSessions.length - 5) {
        // 과거/미래가 각각 5개 이상 있는 경우
        // 파란 테두리를 정확히 가운데(5번 인덱스)에 배치
        startIndex = todayOrNextSessionIndex - 5;
        actualCenterIndex = 5;
        print('[DEBUG][_applySessionSelection] 완벽한 센터링 - todayOrNextSessionIndex: $todayOrNextSessionIndex, startIndex: $startIndex');
      } else if (todayOrNextSessionIndex < 6) {
        // 과거 기록이 부족한 경우 (6개 미만)
        startIndex = 0;
        actualCenterIndex = todayOrNextSessionIndex;
        print('[DEBUG][_applySessionSelection] 과거 부족 - todayOrNextSessionIndex: $todayOrNextSessionIndex, actualCenterIndex: $actualCenterIndex');
      } else {
        // 미래 수업이 부족한 경우 (6개 미만)
        startIndex = allSessions.length - 11;
        actualCenterIndex = todayOrNextSessionIndex - startIndex;
        print('[DEBUG][_applySessionSelection] 미래 부족 - todayOrNextSessionIndex: $todayOrNextSessionIndex, startIndex: $startIndex, actualCenterIndex: $actualCenterIndex');
      }
    }
    
    final endIndex = (startIndex + pageSize).clamp(0, allSessions.length);
    final selectedSessions = allSessions.sublist(startIndex, endIndex);

    print('[DEBUG][_applySessionSelection] 현재 페이지 - 선택된 세션: ${selectedSessions.length}개 (${startIndex}~${endIndex-1})');
    if (selectedSessions.isNotEmpty) {
      print('[DEBUG][_applySessionSelection] 세션 범위: ${selectedSessions.first.dateTime} ~ ${selectedSessions.last.dateTime}');
    }

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
    

    
    // 같은 사이클 내의 동일 클래스의 '원본' 세션만 사용
    // - 대체 세션은 제외(isOverrideReplacement)
    // - 추가(보강 add) 세션은 제외(setId == null)
    final List<ClassSession> sameClassSessions = _classSessions.where((s) {
      final dateOnly = DateTime(s.dateTime.year, s.dateTime.month, s.dateTime.day);
      final inCycle = !dateOnly.isBefore(cycleStartDate) && !dateOnly.isAfter(cycleEndDate);
      return inCycle && s.className == className && !s.isOverrideReplacement && s.setId != null;
    }).toList();
    
    // 날짜/시간 순 정렬
    sameClassSessions.sort((a, b) {
      final da = DateTime(a.dateTime.year, a.dateTime.month, a.dateTime.day, a.dateTime.hour, a.dateTime.minute);
      final db = DateTime(b.dateTime.year, b.dateTime.month, b.dateTime.day, b.dateTime.hour, b.dateTime.minute);
      return da.compareTo(db);
    });
    

    
    // 해당 수업이 몇 번째인지 찾기
    final sessionDateOnly = DateTime(sessionDate.year, sessionDate.month, sessionDate.day);
    // 루트 원본 기준으로 매칭: 이 함수는 카드 인스턴스를 받지 않으므로
    // 세션 고유 앵커는 sessionDate 자체로 두고, 원본/대체 여부는 외부에서 넘겨주는 numberingAnchorDateTime으로 처리함.
    final DateTime anchor = sessionDate;
    final sessionIndex = sameClassSessions.indexWhere((s) {
      final dateOnly = DateTime(s.dateTime.year, s.dateTime.month, s.dateTime.day);
      final anchorDateOnly = DateTime(anchor.year, anchor.month, anchor.day);
      final sTime = Duration(hours: s.dateTime.hour, minutes: s.dateTime.minute);
      final anchorTime = Duration(hours: anchor.hour, minutes: anchor.minute);
      return dateOnly.isAtSameMomentAs(anchorDateOnly) && sTime == anchorTime;
    });
    

    
    return sessionIndex >= 0 ? sessionIndex + 1 : 1;
  }

  Widget _buildClassSessionCard(ClassSession session, int index, double cardWidth) {
    final GlobalKey checkboxKey = GlobalKey();
    final isCenter = index == _centerIndex;
    final isPast = session.dateTime.isBefore(DateTime.now());
    final isGhost = session.isOverrideOriginalGhost;
    final isReplacement = session.isOverrideReplacement;
    
    // 다음 수업(미래 수업 중 가장 가까운 것) 찾기
    final now = DateTime.now();
    final isNextClass = !isPast && _classSessions.where((s) => s.dateTime.isAfter(now)).isNotEmpty && 
        session.dateTime == _classSessions.where((s) => s.dateTime.isAfter(now)).first.dateTime;
    
    // 수업 번호 계산 (사이클-순서-수업명)
    String classNumber = '';
    if (widget.selectedStudent != null) {
      final registrationDate = widget.selectedStudent!.basicInfo.registrationDate;
      if (registrationDate != null) {

        // 보강(대체) 카드의 사이클/회차 번호는 원본 기준으로 계산되도록 앵커 시간 사용
        final DateTime numberingAnchorDateTime =
            (session.overrideOriginalDateTime != null)
                ? session.overrideOriginalDateTime!
                : session.dateTime;
        final cycleNumber = _calculateCycleNumber(registrationDate, numberingAnchorDateTime);
        final sessionNumber = _calculateSessionNumberInCycle(registrationDate, numberingAnchorDateTime, session.className);
        classNumber = '$cycleNumber-$sessionNumber-${session.className}';

      }
    }
    
    // 툴팁 메시지 생성
    String tooltipMessage = '';
    if (classNumber.isNotEmpty) {
      tooltipMessage += '$classNumber';
    }
    // 원본/대체 표시는 상단 배지로 충분하므로, 툴팁은 번호/등하원만 단순 표기
    // 등원/하원 시간
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
    
    // 카드 본문: 체크박스가 시각적으로 카드 밖처럼 보이도록 아래 여백 확보
    Widget cardWidget = Container(
      width: cardWidth,
      height: 104,
      margin: cardMargin,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: isGhost
            ? const Color(0xFF2A2A2A).withOpacity(0.4)
            : isNextClass 
            ? const Color(0xFF1976D2).withOpacity(0.3)  // 다음 수업은 filled box
            : const Color(0xFF2A2A2A),  // 기본 배경
        borderRadius: BorderRadius.circular(8),
        border: isCenter 
            ? Border.all(color: const Color(0xFF1976D2), width: 2)  // 가운데 카드에 파란 테두리
            : isGhost
                ? Border.all(color: Colors.white24, width: 1)
                : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 상단 배지 (제거: 날짜 라인에서만 표시)
          // 1행: 보강/원래/휴강 배지 + 날짜/요일 (한 줄)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isReplacement)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildSmallBadge('보강', const Color(0xFF1976D2)),
                ),
              if (!isReplacement && isGhost && _hasSkipOverrideFor(session))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildSmallBadge('휴강', Colors.black),
                ),
              Text(
                '${session.dateTime.month}/${session.dateTime.day} ${session.dayOfWeek}',
                style: TextStyle(
                  fontSize: 16,
                  color: isGhost ? Colors.white38 : (isPast ? Colors.grey : Colors.white),
                  fontWeight: isCenter ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 2행: 시작시간 - 끝시간
          Center(
            child: Text(
              '${session.dateTime.hour.toString().padLeft(2, '0')}:${session.dateTime.minute.toString().padLeft(2, '0')} - ${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 12, // 2포인트 증가 (12→14)
                color: isGhost ? Colors.white38 : (isPast ? Colors.grey : Colors.white70),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 3행: 수업명 (가운데)
          Center(
            child: Text(
              session.className,
              style: TextStyle(
                fontSize: 15,
                color: isGhost ? Colors.white38 : (isPast ? Colors.grey : Colors.white),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 1),
          // 체크박스는 카드 밖에 겹쳐 보이도록, 별도 Stack에 배치
        ],
      ),
    );
    
    // 카드 탭으로 메뉴 열기 (버튼 제거 대체)
    // 기본: 원본 카드만 메뉴 허용. 단, 휴강 고스트 카드는 미래 일정에 한해 '휴강 취소' 허용
    final bool isSkipGhost = !isReplacement && isGhost && _hasSkipOverrideFor(session);
    // 무단결석 카드도 메뉴 허용, 출석 완료/등원 상태는 방어 다이얼로그 처리
    final bool canShowMenu = (!isGhost && !isPast) || (isSkipGhost && !isPast) || session.attendanceStatus == AttendanceStatus.absent;
    Offset? tapDownPosition;
    // 카드(1~3행)만 탭 영역으로, 체크박스(4행)는 카드 아래에 분리된 영역
    final interactive = Container(
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => tapDownPosition = details.globalPosition,
              onTap: () async {
                if (tapDownPosition == null) return;
                if (!canShowMenu) {
                  // 리스트에서와 동일한 방어 다이얼로그
                  final now = DateTime.now();
                  final isPast = session.dateTime.isBefore(now);
                  final hasAttendance = session.attendanceStatus == AttendanceStatus.arrived || session.attendanceStatus == AttendanceStatus.completed;
                  if (isPast && hasAttendance) {
                    await _showInfoDialog('이미 지난 수업이며 출석이 기록된 회차는 보강을 생성할 수 없습니다.');
                  }
                  return;
                }
                final selected = await showMenu<String>(
                  context: context,
                  position: RelativeRect.fromLTRB(
                    tapDownPosition!.dx,
                    tapDownPosition!.dy,
                    tapDownPosition!.dx,
                    tapDownPosition!.dy,
                  ),
                  color: const Color(0xFF1F1F1F),
                  items: isReplacement
                      ? [
                          _menuItem('replacement_change', '보강시간 변경'),
                          _menuItem('replacement_cancel', '보강 취소'),
                        ]
                      : isSkipGhost
                          ? [
                              _menuItem('skip_cancel', '휴강 취소'),
                            ]
                          : [
                              _menuItem('replace', '보강'),
                              _menuItem('skip', '휴강'),
                            ],
                );
                if (selected == null) return;
                if (isReplacement) {
                  if (selected == 'replacement_change') {
                    await _showChangeReplacementDialog(session);
                  } else if (selected == 'replacement_cancel') {
                    await _confirmAndCancelReplacement(session);
                  }
                  // UI 즉시 반영
                  await Future.delayed(const Duration(milliseconds: 10));
                  if (mounted) setState(() {});
                  return;
                }
                if (isSkipGhost) {
                  if (selected == 'skip_cancel') {
                    await _confirmAndCancelSkip(session);
                  }
                  await Future.delayed(const Duration(milliseconds: 10));
                  if (mounted) setState(() {});
                  return;
                }
                if (selected == 'replace') {
                  final nowLocal = DateTime.now();
                  final isPastLocal = session.dateTime.isBefore(nowLocal);
                  final hasAttendanceLocal = session.attendanceStatus == AttendanceStatus.arrived || session.attendanceStatus == AttendanceStatus.completed;
                  if (isPastLocal && hasAttendanceLocal) {
                    await _showInfoDialog('이미 지난 수업이며 출석이 기록된 회차는 보강을 생성할 수 없습니다.');
                    return;
                  }
                  await _showReplaceDialog(session);
                } else if (selected == 'skip') {
                  await _applySkipOverride(session);
                }
                await Future.delayed(const Duration(milliseconds: 10));
                if (mounted) setState(() {});
              },
              child: cardWidget,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _handleAttendanceClick(session),
                child: Container(
                  key: checkboxKey,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _getCheckboxColor(session.attendanceStatus),
                    border: Border.all(
                      color: _getCheckboxBorderColor(session.attendanceStatus),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: _getCheckboxIcon(session.attendanceStatus),
                ),
              ),
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
        child: interactive,
      );
    } else {
      return interactive;
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

  // 리스트/카드 공통: isReplacement 세션 클릭 시 보강 메뉴 처리
  Future<void> _showChangeReplacementDialog(ClassSession replacementSession) async {
    // 기존 보강을 취소하고 새 보강을 잡는 플로우: 새 시간 선택 후 업데이트
    final result = await _pickDateTime(initial: replacementSession.dateTime);
    if (result == null) return;

    // 기존 planned replace override 찾아 업데이트
    final studentId = widget.selectedStudent!.student.id;
    final overrides = DataManager.instance.getSessionOverridesForStudent(studentId);
    final target = overrides.firstWhere(
      (o) => o.overrideType == OverrideType.replace &&
             o.status == OverrideStatus.planned &&
             o.replacementClassDateTime != null &&
             o.replacementClassDateTime!.isAtSameMomentAs(replacementSession.dateTime),
      orElse: () => null as SessionOverride,
    );
    if (target == null) {
      await _showInfoDialog('변경할 보강을 찾지 못했습니다.');
      return;
    }
    final updated = target.copyWith(
      replacementClassDateTime: result,
      updatedAt: DateTime.now(),
    );
    await DataManager.instance.updateSessionOverride(updated);
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
      _loadClassSessions();
      setState(() {});
    }
  }

  Future<void> _confirmAndCancelReplacement(ClassSession replacementSession) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('보강 취소', style: TextStyle(color: Colors.white)),
        content: const Text('해당 보강을 취소하시겠습니까?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('아니오', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('예', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final studentId = widget.selectedStudent!.student.id;
    final overrides = DataManager.instance.getSessionOverridesForStudent(studentId);
    final target = overrides.firstWhere(
      (o) => o.overrideType == OverrideType.replace &&
             o.status == OverrideStatus.planned &&
             o.replacementClassDateTime != null &&
             o.replacementClassDateTime!.isAtSameMomentAs(replacementSession.dateTime),
      orElse: () => null as SessionOverride,
    );
    if (target == null) {
      await _showInfoDialog('취소할 보강을 찾지 못했습니다.');
      return;
    }
    print('[DEBUG][cancelReplacement] target.id=${target.id} original=${target.originalClassDateTime} replacement=${target.replacementClassDateTime}');

    // 원래 수업이 미래면 원래 일정 복구, 과거면 이번 회차 건너뛰기 처리
    final originalDt = target.originalClassDateTime;
    if (originalDt != null) {
      final isPast = originalDt.isBefore(DateTime.now());
      if (isPast) {
        // skip planned 생성
        await _applySkipOverride(ClassSession(
          dateTime: originalDt,
          className: replacementSession.className,
          dayOfWeek: replacementSession.dayOfWeek,
          duration: replacementSession.duration,
          setId: replacementSession.setId,
          weeklyOrder: replacementSession.weeklyOrder,
          weekNumber: replacementSession.weekNumber,
        ));
      } else {
        print('[DEBUG][cancelReplacement] original is future → just cancel replacement');
      }
    }
    await DataManager.instance.cancelSessionOverride(target.id);
    if (mounted) {
      // 데이터 소스 새로고침 유도
      await Future.delayed(const Duration(milliseconds: 50));
      print('[DEBUG][cancelReplacement] canceled override updated, reloading sessions');
      _loadClassSessions();
      setState(() {});
    }
  }

  Future<DateTime?> _pickDateTime({required DateTime initial}) async {
    DateTime selectedDate = initial;
    TimeOfDay selectedTime = TimeOfDay.fromDateTime(initial);
    final date = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(DateTime.now().year + 2),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF18181A),
        ),
        child: child!,
      ),
    );
    if (date == null) return null;
    selectedDate = date;
    final time = await showTimePicker(
      context: context,
      initialTime: selectedTime,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
          dialogBackgroundColor: const Color(0xFF18181A),
        ),
        child: child!,
      ),
    );
    if (time == null) return null;
    selectedTime = time;
    return DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );
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

  // 작은 배지 위젯
  Widget _buildSmallBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }

  bool _hasSkipOverrideFor(ClassSession session) {
    if (widget.selectedStudent == null) return false;
    final sid = widget.selectedStudent!.student.id;
    for (final o in DataManager.instance.getSessionOverridesForStudent(sid)) {
      if (o.overrideType == OverrideType.skip && o.status == OverrideStatus.planned && o.originalClassDateTime != null) {
        if (o.originalClassDateTime!.year == session.dateTime.year &&
            o.originalClassDateTime!.month == session.dateTime.month &&
            o.originalClassDateTime!.day == session.dateTime.day &&
            o.originalClassDateTime!.hour == session.dateTime.hour &&
            o.originalClassDateTime!.minute == session.dateTime.minute) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _confirmAndCancelSkip(ClassSession ghostSession) async {
    // 과거 일정은 취소 불가
    if (ghostSession.dateTime.isBefore(DateTime.now())) {
      await _showInfoDialog('이미 지난 일정의 휴강은 취소할 수 없습니다.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('휴강 취소', style: TextStyle(color: Colors.white)),
        content: const Text('이 회차의 휴강을 취소하고 원래 일정을 복구할까요?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('아니오', style: TextStyle(color: Colors.white70))),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('예', style: TextStyle(color: Colors.white))),
        ],
      ),
    );
    if (confirm != true) return;

    final sid = widget.selectedStudent!.student.id;
    final overrides = DataManager.instance.getSessionOverridesForStudent(sid);
    final target = overrides.firstWhere(
      (o) => o.overrideType == OverrideType.skip &&
             o.status == OverrideStatus.planned &&
             o.originalClassDateTime != null &&
             o.originalClassDateTime!.isAtSameMomentAs(ghostSession.dateTime),
      orElse: () => null as SessionOverride,
    );
    if (target == null) {
      await _showInfoDialog('취소할 휴강을 찾지 못했습니다.');
      return;
    }
    await DataManager.instance.cancelSessionOverride(target.id);
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
      _loadClassSessions();
      setState(() {});
    }
  }

  PopupMenuItem<String> _menuItem(String value, String text) {
    return PopupMenuItem<String>(
      value: value,
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white),
        child: Text(text),
      ),
    );
  }

  Future<void> _showInfoDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        content: Text(message, style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('확인', style: TextStyle(color: Colors.white70)),
          )
        ],
      ),
    );
  }

  Future<void> _applySkipOverride(ClassSession session) async {
    try {
      final studentId = widget.selectedStudent!.student.id;
      final isPast = session.dateTime.isBefore(DateTime.now());
      final ov = SessionOverride(
        studentId: studentId,
        overrideType: OverrideType.skip,
        status: OverrideStatus.planned,
        originalClassDateTime: session.dateTime,
        durationMinutes: session.duration,
        reason: OverrideReason.makeup,
      );
      await DataManager.instance.addSessionOverride(ov);
      if (isPast) {
        // 과거 회차의 휴강: 기존 출석 기록이 있으면 제거하여 상태를 비움
        final existing = DataManager.instance.getAttendanceRecord(studentId, session.dateTime);
        if (existing != null && existing.id != null) {
          await DataManager.instance.deleteAttendanceRecord(existing.id!);
        }
        // 과거 회차의 휴강은 취소 불가 안내
        await _showInfoDialog('이미 지난 수업의 휴강은 취소할 수 없습니다.');
      }
      // 즉시 UI에 반영
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 30));
        _loadClassSessions();
        setState(() {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('이번 회차가 건너뛰기로 설정되었습니다.'),
          backgroundColor: Color(0xFF1976D2),
          duration: Duration(milliseconds: 1500),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('건너뛰기 설정 실패: $e'),
          backgroundColor: const Color(0xFFE53E3E),
        ));
      }
    }
  }

  Future<void> _showReplaceDialog(ClassSession session) async {
    DateTime targetDate = session.dateTime;
    TimeOfDay targetTime = TimeOfDay.fromDateTime(session.dateTime);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              title: const Text('이번 회차만 변경', style: TextStyle(color: Colors.white, fontSize: 18)),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.calendar_today, color: Colors.white70),
                      title: Text(
                        '${targetDate.year}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: targetDate,
                          firstDate: DateTime.now().subtract(const Duration(days: 1)),
                          lastDate: DateTime(DateTime.now().year + 2),
                          builder: (context, child) => Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                              dialogBackgroundColor: const Color(0xFF18181A),
                            ),
                            child: child!,
                          ),
                        );
                        if (picked != null) setDialogState(() => targetDate = picked);
                      },
                      tileColor: const Color(0xFF2A2A2A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      leading: const Icon(Icons.access_time, color: Colors.white70),
                      title: Text(
                        '${targetTime.hour.toString().padLeft(2, '0')}:${targetTime.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: targetTime,
                          builder: (context, child) => Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                              dialogBackgroundColor: const Color(0xFF18181A),
                            ),
                            child: child!,
                          ),
                        );
                        if (picked != null) setDialogState(() => targetTime = picked);
                      },
                      tileColor: const Color(0xFF2A2A2A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                ),
                TextButton(
                  onPressed: () {
                    final dt = DateTime(
                      targetDate.year,
                      targetDate.month,
                      targetDate.day,
                      targetTime.hour,
                      targetTime.minute,
                    );
                    Navigator.of(context).pop({'dateTime': dt});
                  },
                  child: const Text('적용', style: TextStyle(color: Colors.white)),
                  style: TextButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                ),
              ],
            );
          },
        );
      },
    );
    if (result != null && result['dateTime'] is DateTime) {
      await _applyReplaceOverride(session, result['dateTime'] as DateTime);
    }
  }

  Future<void> _applyReplaceOverride(ClassSession session, DateTime replacementDateTime) async {
    try {
      final studentId = widget.selectedStudent!.student.id;
      // 보강 카드에 대해 또 "이번 회차만 변경"을 수행하면
      // 새로운 대체를 추가하지 않고 기존 override의 replacement만 갱신한다.
      if (session.isOverrideReplacement) {
        final existing = DataManager.instance.sessionOverrides.firstWhere(
          (o) => o.studentId == studentId &&
                 o.overrideType == OverrideType.replace &&
                 o.status == OverrideStatus.planned &&
                 o.replacementClassDateTime != null &&
                 o.replacementClassDateTime!.isAtSameMomentAs(session.dateTime),
          orElse: () => null as SessionOverride,
        );
        if (existing != null) {
          final updated = existing.copyWith(
            setId: session.setId ?? existing.setId,
            replacementClassDateTime: replacementDateTime,
            updatedAt: DateTime.now(),
          );
          await DataManager.instance.updateSessionOverride(updated);
        } else {
          // 안전망: 기존을 찾지 못하면 새 override 생성
          final ov = SessionOverride(
            studentId: studentId,
            setId: session.setId,
            overrideType: OverrideType.replace,
            status: OverrideStatus.planned,
            originalClassDateTime: session.overrideOriginalDateTime ?? session.dateTime,
            replacementClassDateTime: replacementDateTime,
            durationMinutes: session.duration,
            reason: OverrideReason.makeup,
          );
          await DataManager.instance.addSessionOverride(ov);
        }
      } else {
        final ov = SessionOverride(
          studentId: studentId,
          setId: session.setId,
          overrideType: OverrideType.replace,
          status: OverrideStatus.planned,
          originalClassDateTime: session.dateTime,
          replacementClassDateTime: replacementDateTime,
          durationMinutes: session.duration,
          reason: OverrideReason.makeup,
        );
        await DataManager.instance.addSessionOverride(ov);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('이번 회차 변경이 적용되었습니다.'),
          backgroundColor: Color(0xFF1976D2),
          duration: Duration(milliseconds: 1500),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('변경 적용 실패: $e'),
          backgroundColor: const Color(0xFFE53E3E),
        ));
      }
    }
  }

  Future<void> _handleAttendanceClick(ClassSession session) async {
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
          // 출석 해제 - 무단결석으로 변경
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
              content: Text('출석이 해제되어 무단결석으로 변경되었습니다.'),
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
    if (widget.listOnly) {
      // 리스트만 띄우는 용도일 때는 본문 UI를 렌더링하지 않음
      return const SizedBox.shrink();
    }
    return IntrinsicHeight(
      child: ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (context, attendanceRecords, child) {

        if (widget.selectedStudent == null) {
          return Container(
            height: 160,
            margin: const EdgeInsets.only(bottom: 24, right: 24),
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
          margin: const EdgeInsets.only(bottom: 24, right: 1),
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
                    const Spacer(),
                    // 리스트 버튼 (다이얼로그) - 크기 10% 키움
                    TextButton.icon(
                      onPressed: () => _showSessionListDialog(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(horizontal: 13.2, vertical: 8.8),
                      ),
                      icon: const Icon(Icons.list, size: 19.8, color: Colors.white70),
                      label: const Text('리스트', style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 수업 목록 (카드)
                (_classSessions.isEmpty)
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            '등록된 수업이 없습니다',
                            style: TextStyle(color: Colors.white54, fontSize: 17),
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final totalWidth = constraints.maxWidth;
                          final availableWidth = totalWidth;
                          final cardMargin = 8; // 카드 간 마진
                          final totalMarginWidth = cardMargin * (_classSessions.length - 1);
                          final cardWidth = (availableWidth - totalMarginWidth) / _classSessions.length;
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
      ),
    );
  }
}

// 공개 유틸: 출석 시간 수정 다이얼로그 (학생 화면 등 외부에서도 사용 가능)
Future<void> showAttendanceEditDialog({
  required BuildContext context,
  required String studentId,
  required DateTime classDateTime,
  required int durationMinutes,
  required String className,
}) async {
  DateTime selectedDate = classDateTime;
  TimeOfDay selectedArrivalTime = TimeOfDay.fromDateTime(classDateTime);
  TimeOfDay selectedDepartureTime = TimeOfDay.fromDateTime(
    classDateTime.add(Duration(minutes: durationMinutes)),
  );

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1F1F1F),
            title: const Text('출석 시간 수정', style: TextStyle(color: Colors.white, fontSize: 18)),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                              colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
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
                  ListTile(
                    leading: const Icon(Icons.login, color: Colors.white70),
                    title: Text('등원 시간: ${selectedArrivalTime.format(context)}', style: const TextStyle(color: Colors.white)),
                    onTap: () async {
                      final TimeOfDay? picked = await showTimePicker(
                        context: context,
                        initialTime: selectedArrivalTime,
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                            dialogBackgroundColor: const Color(0xFF18181A),
                          ),
                          child: child!,
                        ),
                      );
                      if (picked != null) setDialogState(() => selectedArrivalTime = picked);
                    },
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.white70),
                    title: Text('하원 시간: ${selectedDepartureTime.format(context)}', style: const TextStyle(color: Colors.white)),
                    onTap: () async {
                      final TimeOfDay? picked = await showTimePicker(
                        context: context,
                        initialTime: selectedDepartureTime,
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                            dialogBackgroundColor: const Color(0xFF18181A),
                          ),
                          child: child!,
                        ),
                      );
                      if (picked != null) setDialogState(() => selectedDepartureTime = picked);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('취소', style: TextStyle(color: Colors.grey))),
              TextButton(onPressed: () => Navigator.of(context).pop({'action': 'delete'}), child: const Text('출석 해제', style: TextStyle(color: Color(0xFFE53E3E)))),
              TextButton(
                onPressed: () {
                  final arrivalDateTime = DateTime(
                    selectedDate.year, selectedDate.month, selectedDate.day, selectedArrivalTime.hour, selectedArrivalTime.minute,
                  );
                  final departureDateTime = DateTime(
                    selectedDate.year, selectedDate.month, selectedDate.day, selectedDepartureTime.hour, selectedDepartureTime.minute,
                  );
                  Navigator.of(context).pop({'action': 'update', 'arrivalTime': arrivalDateTime, 'departureTime': departureDateTime});
                },
                child: const Text('확인', style: TextStyle(color: Color(0xFF1976D2))),
              ),
            ],
          );
        },
      );
    },
  );

  if (result != null) {
    final classEndTime = classDateTime.add(Duration(minutes: durationMinutes));
    if (result['action'] == 'delete') {
      await DataManager.instance.saveOrUpdateAttendance(
        studentId: studentId,
        classDateTime: classDateTime,
        classEndTime: classEndTime,
        className: className,
        isPresent: false,
        arrivalTime: null,
        departureTime: null,
      );
    } else {
      await DataManager.instance.saveOrUpdateAttendance(
        studentId: studentId,
        classDateTime: classDateTime,
        classEndTime: classEndTime,
        className: className,
        isPresent: true,
        arrivalTime: result['arrivalTime'],
        departureTime: result['departureTime'],
      );
    }
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
  final int? weeklyOrder; // 주간 내 몇번째 수업인지
  final int? weekNumber;  // 등록 기준 몇 주차인지(1부터)
  bool isAttended;
  DateTime? arrivalTime;
  DateTime? departureTime;
  AttendanceStatus attendanceStatus;
  // 보강/예외 표시용 메타
  final bool isOverrideReplacement; // 대체 회차
  final bool isOverrideOriginalGhost; // 원래 회차(표시용)
  final DateTime? overrideOriginalDateTime; // 대체가 참조하는 원본 시간

  ClassSession({
    required this.dateTime,
    required this.className,
    required this.dayOfWeek,
    required this.duration,
    this.setId,
    this.weeklyOrder,
    this.weekNumber,
    this.isAttended = false,
    this.arrivalTime,
    this.departureTime,
    this.attendanceStatus = AttendanceStatus.none,
    this.isOverrideReplacement = false,
    this.isOverrideOriginalGhost = false,
    this.overrideOriginalDateTime,
  });
}