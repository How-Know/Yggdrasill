import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/payment_record.dart';
import 'package:mneme_flutter/models/student_time_block.dart';
import 'package:mneme_flutter/services/academy_db.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import '../components/attendance_check_view.dart';
import '../../../models/student.dart';

class AttendanceView extends StatefulWidget {
  const AttendanceView({Key? key}) : super(key: key);

  @override
  State<AttendanceView> createState() => _AttendanceViewState();
}

class _AttendanceViewState extends State<AttendanceView> {
  StudentWithInfo? _selectedStudent;
  final Map<String, bool> _isExpanded = {};
  DateTime _currentDate = DateTime.now();
  DateTime _currentCalendarDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await _ensurePaymentRecordsTable();
    // DataManager.initialize()에서 이미 로딩되므로 중복 제거
    if (mounted) {
      setState(() {});
    }
  }

  // payment_records 테이블 존재 여부 확인 및 생성
  Future<void> _ensurePaymentRecordsTable() async {
    try {
      await AcademyDbService.instance.ensurePaymentRecordsTable();
    } catch (e) {
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // 왼쪽 학생 리스트 컨테이너
              Container(
                width: 260,
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F1F),
                  borderRadius: BorderRadius.circular(12),
                ),
                margin: const EdgeInsets.only(right: 16, left: 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        '학생 목록',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // 학생 리스트
                    Expanded(
                      child: ValueListenableBuilder<List<StudentWithInfo>>(
                        valueListenable: DataManager.instance.studentsNotifier,
                        builder: (context, students, child) {
                          final gradeGroups = _groupStudentsByGrade(students);
                          return ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            children: [
                              ...gradeGroups.entries.map((entry) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: _buildGradeGroup(entry.key, entry.value),
                                );
                              }).toList(),
                              const SizedBox(height: 32),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // 오른쪽 영역: (학생정보 + 달력) + 수강료 납부
              Expanded(
                child: Column(
                  children: [
                    // 상단: 학생정보 + 달력 통합 컨테이너
                    Container(
                      height: MediaQuery.of(context).size.height * 0.4,
                      margin: const EdgeInsets.only(top: 16, right: 24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.black, width: 1),
                      ),
                                              child: Row(
                          children: [
                            // 학생 정보 영역
                            Expanded(
                              flex: 4,
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: _selectedStudent != null
                                    ? _buildStudentInfoDisplay(_selectedStudent!)
                                    : const Center(
                                        child: Text(
                                          '학생을 선택해주세요',
                                          style: TextStyle(color: Colors.white70, fontSize: 16),
                                        ),
                                      ),
                              ),
                            ),
                            // 중간 요약 영역
                            Expanded(
                              flex: 4,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.black54, width: 1),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Center(
                                    child: Text(
                                      '전체 요약',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 달력 영역
                            Expanded(
                              flex: 5,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                                child: Column(
                                children: [
                                  // 달력 헤더
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
                                          onPressed: () => setState(() => _currentDate = DateTime(_currentDate.year, _currentDate.month - 1)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${_currentDate.year}년 ${_currentDate.month}월',
                                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                                          onPressed: () => setState(() => _currentDate = DateTime(_currentDate.year, _currentDate.month + 1)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // 달력 본체
                                  Expanded(child: _buildCalendar()),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 하단: 수강료 납부 + 출석체크
                    const SizedBox(height: 16),
                    Expanded(
                      child: Column(
                        children: [
                          // 수강료 납부
                          Container(
                            height: 240,
                            margin: const EdgeInsets.only(bottom: 16, right: 24),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F1F1F),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.black, width: 1),
                            ),
                            child: _selectedStudent != null
                                ? _buildPaymentSchedule(_selectedStudent!)
                                : const Center(
                                    child: Text(
                                      '학생을 선택하면 수강료 납부 일정이 표시됩니다.',
                                      style: TextStyle(color: Colors.white70, fontSize: 16),
                                    ),
                                  ),
                          ),
                          // 출석 체크
                          AttendanceCheckView(
                            selectedStudent: _selectedStudent,
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 학생 리스트 학년별 그룹핑
  Map<String, List<StudentWithInfo>> _groupStudentsByGrade(List<StudentWithInfo> students) {
    final Map<String, List<StudentWithInfo>> gradeGroups = {};
    for (var student in students) {
      // educationLevel과 grade를 조합하여 '초6', '중1' 등으로 표시
      final levelPrefix = _getEducationLevelPrefix(student.student.educationLevel);
      final grade = '$levelPrefix${student.student.grade}';
      if (gradeGroups[grade] == null) {
        gradeGroups[grade] = [];
      }
      gradeGroups[grade]!.add(student);
    }

    // 학년 순서대로 정렬 (초-중-고 순)
    final sortedKeys = gradeGroups.keys.toList()
      ..sort((a, b) {
        final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        const levelOrder = {'초': 1, '중': 2, '고': 3};
        final aLevel = levelOrder[a.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;
        final bLevel = levelOrder[b.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;

        if (aLevel != bLevel) {
          return aLevel.compareTo(bLevel);
        }
        return aNum.compareTo(bNum);
      });

    return {for (var key in sortedKeys) key: gradeGroups[key]!};
  }

  // 교육 단계 접두사 반환
  String _getEducationLevelPrefix(dynamic educationLevel) {
    if (educationLevel.toString().contains('elementary')) return '초';
    if (educationLevel.toString().contains('middle')) return '중';
    if (educationLevel.toString().contains('high')) return '고';
    return '';
  }

  // 학년 그룹 위젯
  Widget _buildGradeGroup(String grade, List<StudentWithInfo> students) {
    final key = grade;
    final isExpanded = _isExpanded[key] ?? false;
    return Container(
      decoration: BoxDecoration(
        color: isExpanded ? const Color(0xFF2A2A2A) : const Color(0xFF2D2D2D), // 접혀있을 때도 배경색 지정
        borderRadius: BorderRadius.circular(0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                _isExpanded[key] = !isExpanded;
              });
            },
            child: Container(
              color: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Row(
                children: [
                  Text(
                    '  $grade   ${students.length}명', // 인원수 추가
                    style: const TextStyle(
                      color: Color(0xFFB0B0B0), // 덜 밝은 흰색
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: const Color(0xFFB0B0B0), // 덜 밝은 흰색
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: students.length,
              itemBuilder: (context, index) {
                final studentWithInfo = students[index];
                return _AttendanceStudentCard(
                  studentWithInfo: studentWithInfo,
                  isSelected: _selectedStudent?.student.id == studentWithInfo.student.id,
                  onTap: () {
                    setState(() {
                      _selectedStudent = studentWithInfo;
                    });
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  // 학생 정보 표시 위젯
  Widget _buildStudentInfoDisplay(StudentWithInfo studentWithInfo) {
    final student = studentWithInfo.student;
    final timeBlocks = DataManager.instance.studentTimeBlocks
        .where((tb) => tb.studentId == student.id)
        .toList();
    final classSchedules = _groupTimeBlocksByClass(timeBlocks);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start, // 상단 정렬
        children: [
          Row(
            children: [
              Text(
                student.name,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Text(
                '${student.school} / ${_getEducationLevelKorean(student.educationLevel)} / ${student.grade}학년', // 한글로 변경
                style: const TextStyle(fontSize: 16, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white24),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...classSchedules.entries.map((entry) {
                    final className = entry.key;
                    final schedules = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            className,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          ...schedules.map((schedule) => Text(
                            '${schedule['day']} ${schedule['start']} ~ ${schedule['end']}',
                            style: const TextStyle(fontSize: 17, color: Colors.white70),
                          )),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 교육 단계 한글 변환
  String _getEducationLevelKorean(dynamic educationLevel) {
    if (educationLevel.toString().contains('elementary')) return '초등';
    if (educationLevel.toString().contains('middle')) return '중등';
    if (educationLevel.toString().contains('high')) return '고등';
    return educationLevel.toString();
  }

  // 수업 시간 블록 그룹핑
  Map<String, List<Map<String, String>>> _groupTimeBlocksByClass(List<StudentTimeBlock> timeBlocks) {
    final Map<String?, List<StudentTimeBlock>> blocksBySet = {}; // 키 타입을 String?로 변경
    for (var block in timeBlocks) {
      if (blocksBySet[block.setId] == null) {
        blocksBySet[block.setId] = [];
      }
      blocksBySet[block.setId]!.add(block);
    }

    final Map<String, List<Map<String, String>>> classSchedules = {};
    blocksBySet.forEach((setId, blocks) {
      if (blocks.isEmpty) return;
      final firstBlock = blocks.first;
      String className = '수업';
      try {
        // sessionTypeId를 직접 사용하여 ClassInfo를 찾습니다.
        if (firstBlock.sessionTypeId != null) {
          final classInfo = DataManager.instance.classes.firstWhere((c) => c.id == firstBlock.sessionTypeId);
          className = classInfo.name;
        }
      } catch (e) {
        // 해당 클래스 정보가 없을 경우 기본값 사용
      }

      final schedule = _formatTimeBlocks(blocks);
      if (classSchedules[className] == null) {
        classSchedules[className] = [];
      }
      classSchedules[className]!.add(schedule);
    });

    return classSchedules;
  }

  // 시간 포맷팅
  Map<String, String> _formatTimeBlocks(List<StudentTimeBlock> blocks) {
    if (blocks.isEmpty) return {};
    final dayOfWeek = ['월', '화', '수', '목', '금', '토', '일'];
    final firstBlock = blocks.first;
    final lastBlock = blocks.last;

    int startHour = firstBlock.startHour;
    int startMinute = firstBlock.startMinute;
    
    // endHour와 endMinute는 duration을 사용하여 계산합니다.
    final startTime = DateTime(2023, 1, 1, lastBlock.startHour, lastBlock.startMinute);
    final endTime = startTime.add(lastBlock.duration);
    int endHour = endTime.hour;
    int endMinute = endTime.minute;

    return {
      'day': dayOfWeek[firstBlock.dayIndex], // day -> dayIndex
      'start': '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}',
      'end': '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}',
    };
  }

  // 달력 위젯
  Widget _buildCalendar() {
    final daysInMonth = DateUtils.getDaysInMonth(_currentDate.year, _currentDate.month);
    final firstDayOfMonth = DateTime(_currentDate.year, _currentDate.month, 1);
    final weekdayOfFirstDay = firstDayOfMonth.weekday; // 월요일=1, 일요일=7

    final today = DateTime.now();
    final dayOfWeekHeaders = ['월', '화', '수', '목', '금', '토', '일'];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: dayOfWeekHeaders.map((day) => Text(day, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))).toList(),
          ),
        ),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
            itemCount: daysInMonth + weekdayOfFirstDay - 1,
            itemBuilder: (context, index) {
              if (index < weekdayOfFirstDay - 1) {
                return Container(); // Empty container for days before the 1st
              }
              final dayNumber = index - (weekdayOfFirstDay - 1) + 1;
              final date = DateTime(_currentDate.year, _currentDate.month, dayNumber);
              final isToday = DateUtils.isSameDay(date, today);

              return Container(
                margin: const EdgeInsets.all(5),
                decoration: isToday
                    ? BoxDecoration(
                        border: Border.all(color: const Color(0xFF1976D2), width: 3),
                        borderRadius: BorderRadius.circular(7),
                      )
                    : null,
                child: Center(
                  child: Text(
                    '$dayNumber',
                    style: TextStyle(
                      color: isToday ? Colors.white : Colors.white, 
                      fontSize: 17,
                      fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // 수강료 납부 스케줄 위젯
  Widget _buildPaymentSchedule(StudentWithInfo studentWithInfo) {
    final basicInfo = studentWithInfo.basicInfo;
    final registrationDate = basicInfo.registrationDate;

    if (registrationDate == null) {
      return const Center(child: Text('등록일자 정보가 없습니다.', style: TextStyle(color: Colors.white70)));
    }

    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final registrationMonth = DateTime(registrationDate.year, registrationDate.month);
    
    // 등록일 이후의 달만 포함하도록 수정
    final candidateMonths = [
      DateTime(currentMonth.year, currentMonth.month - 2),
      DateTime(currentMonth.year, currentMonth.month - 1),
      currentMonth,
      DateTime(currentMonth.year, currentMonth.month + 1),
      DateTime(currentMonth.year, currentMonth.month + 2),
    ];
    
    // 등록월 이후의 달만 필터링
    final validMonths = candidateMonths
        .where((month) => month.isAfter(registrationMonth) || month.isAtSameMomentAs(registrationMonth))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
                      Row(
              children: [
                const Text(
                  '수강료 납부',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white), // 2포인트 증가 (18 → 20)
                ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: _showDueDateEditDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8), // 패딩 증가
                    decoration: BoxDecoration(
                      color: const Color(0xFF1976D2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '수정', 
                      style: TextStyle(
                        color: Colors.white, 
                        fontWeight: FontWeight.bold,
                        fontSize: 16, // 폰트 크기 증가
                      ),
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 16),
          // 납부 예정일
          Row(
            children: validMonths.asMap().entries.map((entry) {
              final index = entry.key;
              final month = entry.value;
              
              // 동적으로 라벨 생성
              String label;
              final monthDiff = (month.year - currentMonth.year) * 12 + (month.month - currentMonth.month);
              if (monthDiff == 0) {
                label = '이번달';
              } else if (monthDiff < 0) {
                label = '${monthDiff.abs()}달전';
              } else {
                label = '${monthDiff}달후';
              }
              
              final isCurrentMonth = month.year == currentMonth.year && month.month == currentMonth.month;

              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index < validMonths.length - 1 ? 8 : 0),
                  child: _buildPaymentDateCard(
                    _getActualPaymentDateForMonth(studentWithInfo.student.id, registrationDate, month),
                    label,
                    isCurrentMonth,
                    registrationDate,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // 실제 납부일
          Row(
            children: validMonths.asMap().entries.map((entry) {
              final index = entry.key;
              final month = entry.value;
              final paymentDate = _getActualPaymentDateForMonth(studentWithInfo.student.id, registrationDate, month);
              final cycleNumber = _calculateCycleNumber(registrationDate, paymentDate);
              
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index < validMonths.length - 1 ? 8 : 0),
                  child: _buildActualPaymentCard(paymentDate, cycleNumber),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // 납부 예정일 카드
  Widget _buildPaymentDateCard(DateTime paymentDate, String label, bool isCurrentMonth, DateTime registrationDate) {
    final cycleNumber = _calculateCycleNumber(registrationDate, paymentDate);
    return Tooltip(
      message: '$cycleNumber번째',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
          border: isCurrentMonth ? Border.all(color: const Color(0xFF1976D2), width: 2) : Border.all(color: const Color(0xFF444444), width: 1),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: isCurrentMonth ? const Color(0xFF1976D2) : Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(
              '${paymentDate.month}/${paymentDate.day}',
              style: TextStyle(color: isCurrentMonth ? Colors.white : Colors.white70, fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // 실제 납부일 카드
  Widget _buildActualPaymentCard(DateTime paymentDate, int cycleNumber) {
    final record = DataManager.instance.getPaymentRecord(_selectedStudent!.student.id, cycleNumber);
    return GestureDetector(
      onTap: () => _showPaymentDatePicker(record ?? PaymentRecord(studentId: _selectedStudent!.student.id, cycle: cycleNumber, dueDate: paymentDate)),
      child: Container(
        height: 30,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: Colors.transparent),
        ),
        child: Container(
          width: 60,
          height: 40,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.transparent),
          ),
          child: Center(
            child: record?.paidDate != null
                ? Text(
                    '${record!.paidDate!.month}/${record.paidDate!.day}',
                    style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 19, fontWeight: FontWeight.w600),
                  )
                : Container(
                    width: 20,
                    height: 2,
                    decoration: BoxDecoration(color: Colors.white60, borderRadius: BorderRadius.circular(1.5)),
                  ),
          ),
        ),
      ),
    );
  }

  // 납부일 선택 다이얼로그
  Future<void> _showPaymentDatePicker(PaymentRecord record) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: record.paidDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
      locale: const Locale('ko', 'KR'), // 이제 한국어 사용 가능
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF2A2A2A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF1F1F1F),
            // DatePicker 스타일링 추가
            datePickerTheme: DatePickerThemeData(
              headerHeadlineStyle: const TextStyle(fontSize: 14), // 월 폰트 크기 줄임
              weekdayStyle: const TextStyle(fontSize: 11), // 요일 폰트 크기 줄임
            ),
            // 확인 버튼을 알약 형태로
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), // 알약 형태
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1976D2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), // 알약 형태
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final updatedRecord = record.copyWith(paidDate: picked);
      if (record.id != null) {
        await DataManager.instance.updatePaymentRecord(updatedRecord);
      } else {
        await DataManager.instance.addPaymentRecord(updatedRecord);
      }
      setState(() {});
    }
  }

  // 납부 예정일 수정 다이얼로그
  Future<void> _showDueDateEditDialog() async {
    if (_selectedStudent == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('학생을 먼저 선택해주세요.'), backgroundColor: Colors.orange));
      return;
    }

    final student = _selectedStudent!;
    final basicInfo = student.basicInfo;
    
    if (basicInfo.registrationDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('학생의 등록일자 정보가 없습니다.'), backgroundColor: Colors.red));
      return;
    }

    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    
    final currentCycleDate = _getActualPaymentDateForMonth(student.student.id, basicInfo.registrationDate!, currentMonth);
    final currentCycle = _calculateCycleNumber(basicInfo.registrationDate!, currentCycleDate);
    final paymentRecords = DataManager.instance.paymentRecordsNotifier.value;
    final hasCurrentPayment = paymentRecords.any((r) => r.studentId == student.student.id && r.cycle == currentCycle && r.paidDate != null);
    
    final targetMonth = hasCurrentPayment ? DateTime(now.year, now.month + 1) : currentMonth;
    final targetDate = _getActualPaymentDateForMonth(student.student.id, basicInfo.registrationDate!, targetMonth);
    final targetCycle = _calculateCycleNumber(basicInfo.registrationDate!, targetDate);

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: targetDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
      locale: const Locale('ko', 'KR'), // 이제 한국어 사용 가능
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF2A2A2A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF1F1F1F),
            // DatePicker 스타일링 추가
            datePickerTheme: DatePickerThemeData(
              headerHeadlineStyle: const TextStyle(fontSize: 14), // 월 폰트 크기 줄임
              weekdayStyle: const TextStyle(fontSize: 11), // 요일 폰트 크기 줄임
            ),
            // 확인 버튼을 알약 형태로
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), // 알약 형태
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1976D2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), // 알약 형태
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      try {
        await _updateFuturePaymentDueDates(student.student.id, basicInfo.registrationDate!, targetCycle, picked.day);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${hasCurrentPayment ? "다음" : "현재"} 사이클부터 납부 예정일이 수정되었습니다.'), backgroundColor: const Color(0xFF4CAF50)));
        setState(() {});
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수정 중 오류가 발생했습니다: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // 미래 납부 예정일 업데이트
  Future<void> _updateFuturePaymentDueDates(String studentId, DateTime registrationDate, int fromCycle, int newDay) async {
    final paymentRecords = DataManager.instance.paymentRecordsNotifier.value;
    
    for (int i = 0; i < 12; i++) {
      final futureMonth = DateTime(DateTime.now().year, DateTime.now().month + i);
      final originalDueDate = _getPaymentDateForMonth(registrationDate, futureMonth);
      final cycle = _calculateCycleNumber(registrationDate, originalDueDate);
      
      if (cycle >= fromCycle) {
        int day = newDay;
        final lastDayOfMonth = DateTime(futureMonth.year, futureMonth.month + 1, 0).day;
        if (day > lastDayOfMonth) day = lastDayOfMonth;
        
        final newDueDate = DateTime(futureMonth.year, futureMonth.month, day);
        
        final existingRecord = paymentRecords.firstWhere(
          (r) => r.studentId == studentId && r.cycle == cycle,
          orElse: () => PaymentRecord(studentId: studentId, cycle: cycle, dueDate: newDueDate),
        );
        
        final updatedRecord = existingRecord.copyWith(dueDate: newDueDate);
        
        if (existingRecord.id != null) {
          await DataManager.instance.updatePaymentRecord(updatedRecord);
        } else {
          await DataManager.instance.addPaymentRecord(updatedRecord);
        }
      }
    }
  }

  // 기본 납부 예정일 계산
  DateTime _getPaymentDateForMonth(DateTime registrationDate, DateTime targetMonth) {
    int targetDay = registrationDate.day;
    final lastDayOfMonth = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;
    if (targetDay > lastDayOfMonth) {
      targetDay = lastDayOfMonth;
    }
    return DateTime(targetMonth.year, targetMonth.month, targetDay);
  }

  // 실제 납부 예정일 계산 (DB override 확인)
  DateTime _getActualPaymentDateForMonth(String studentId, DateTime registrationDate, DateTime targetMonth) {
    final defaultDate = _getPaymentDateForMonth(registrationDate, targetMonth);
    final cycle = _calculateCycleNumber(registrationDate, defaultDate);
    final paymentRecords = DataManager.instance.paymentRecordsNotifier.value;
    try {
      final existingRecord = paymentRecords.firstWhere((r) => r.studentId == studentId && r.cycle == cycle);
      return existingRecord.dueDate;
    } catch (e) {
      return defaultDate;
    }
  }

  // 사이클 번호 계산
  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    int months = (paymentDate.year - registrationDate.year) * 12 + (paymentDate.month - registrationDate.month);
    if (paymentDate.day < registrationDate.day) {
      months--;
    }
    // 사이클은 최소 1부터 시작하도록 보장
    return (months + 1).clamp(1, double.infinity).toInt();
  }
}

// 학생 리스트 카드
class _AttendanceStudentCard extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final bool isSelected;
  final VoidCallback onTap;

  const _AttendanceStudentCard({
    required this.studentWithInfo,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_AttendanceStudentCard> createState() => _AttendanceStudentCardState();
}

class _AttendanceStudentCardState extends State<_AttendanceStudentCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    
    return Tooltip(
      message: student.school,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 17),
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        onEnter: (_) {
          if (!widget.isSelected) {
            setState(() => _isHovered = true);
          }
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: () {
            setState(() => _isHovered = false);
            widget.onTap();
          },
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            decoration: BoxDecoration(
              border: widget.isSelected
                  ? Border.all(color: const Color(0xFF1976D2), width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Text(
                  student.name,
                  style: const TextStyle(
                    color: Color(0xFFE0E0E0),
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                  ),
                ),
                if (_isHovered && !widget.isSelected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1976D2),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
