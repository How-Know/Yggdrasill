class CycleAttendanceSummary {
  final String studentId;
  final int cycle;
  /// cycle 시작(포함). 보통 dueDate의 date-only (local)
  final DateTime start;
  /// cycle 종료(미포함). 보통 다음 dueDate의 date-only (local)
  final DateTime end;

  /// cycle 구간 내 "계획된 수업(예정 포함 전체)" 횟수
  final int plannedCount;
  /// cycle 구간 내 "실제 수행" 횟수 (출석/등원 기록이 있는 경우)
  final int actualCount;
  /// cycle 구간 내 "명시적 결석" 횟수 (isPlanned=false && 미출석)
  final int absentCount;
  /// cycle 구간 내 "미기록(예정만 있고 출석/결석 확정이 없는 상태)" 횟수 (isPlanned=true && 미출석)
  final int pendingCount;

  /// 계획된 총 수업시간(분): class_end_time - class_date_time 합
  final int plannedMinutes;
  /// 실제 수행 총 수업시간(분): 기본은 class_end_time - class_date_time 합(출석/등원 기록이 있는 건만)
  final int actualMinutes;
  /// 결석(명시적) 총 수업시간(분): plannedMinutes 중 결석으로 분류된 것
  final int absentMinutes;
  /// 미기록 총 수업시간(분): plannedMinutes 중 미기록으로 분류된 것
  final int pendingMinutes;

  const CycleAttendanceSummary({
    required this.studentId,
    required this.cycle,
    required this.start,
    required this.end,
    required this.plannedCount,
    required this.actualCount,
    required this.absentCount,
    required this.pendingCount,
    required this.plannedMinutes,
    required this.actualMinutes,
    required this.absentMinutes,
    required this.pendingMinutes,
  });

  double get plannedHours => plannedMinutes / 60.0;
  double get actualHours => actualMinutes / 60.0;
}


