import 'package:flutter/material.dart';
import '../../../models/attendance_record.dart';
import '../../../models/student_payment_info.dart';
import '../../../services/data_manager.dart';
import '../../../models/session_override.dart';
import '../../../utils/attendance_judgement.dart';

/// 달력에 출석 상태를 표시하는 인디케이터 컴포넌트
///
/// 표시 규칙:
/// 1. 정상 등하원: 초록색 밑줄 (Color(0xFF33A373))
/// 2. 지각 등원: 주황색 밑줄 (Color(0xFFFB8C00))
/// 3. 무단 결석: 빨간색 밑줄 (Color(0xFFE57373))
class AttendanceIndicator extends StatelessWidget {
  static const Color _colorPresent = Color(0xFF33A373);
  static const Color _colorLate = Color(0xFFF2B45B);
  static const Color _colorAbsent = Color(0xFFE57373);
  static const Color _colorPlanned = Color(0xFF3C4747); // ✅ 예정 수업(회색)
  static const Color _colorEarlyLeave = Color(0xFF7B62D3); // 조퇴(퍼플)

  final String studentId;
  final DateTime date;
  final double width;
  final double thickness;

  const AttendanceIndicator({
    Key? key,
    required this.studentId,
    required this.date,
    this.width = 10.0, // 기존보다 절반 너비로 축소
    this.thickness = 3.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final attendanceRecords = _getAttendanceRecordsForDate();

    if (attendanceRecords.isEmpty) {
      return const SizedBox.shrink(); // 출석 데이터가 없으면 표시하지 않음
    }

    return FutureBuilder<Color?>(
      future: _determineAttendanceColor(attendanceRecords),
      builder: (context, colorSnapshot) {
        if (!colorSnapshot.hasData || colorSnapshot.data == null) {
          return const SizedBox.shrink(); // 표시할 상태가 없으면 숨김
        }

        return Container(
          width: width,
          height: thickness,
          decoration: BoxDecoration(
            color: colorSnapshot.data!,
            borderRadius: BorderRadius.circular(thickness / 2),
          ),
        );
      },
    );
  }

  /// 해당 날짜의 출석 기록을 가져옵니다
  List<AttendanceRecord> _getAttendanceRecordsForDate() {
    final allRecords = DataManager.instance.attendanceRecords;
    final overrides = DataManager.instance.sessionOverrides;
    final dateStart = DateTime(date.year, date.month, date.day);
    final dateEnd = dateStart.add(const Duration(days: 1));

    // 기본: 해당 날짜의 모든 출석 기록
    final dailyRecords = allRecords.where((record) {
      return record.studentId == studentId &&
          record.classDateTime.isAfter(dateStart) &&
          record.classDateTime.isBefore(dateEnd);
    }).toList();

    // 밑줄은 "예정 수업" 기준으로만 표기: 추가수업(OverrideType.add)에 해당하는 출석 기록은 제외
    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        a.hour == b.hour &&
        a.minute == b.minute;

    final addOverrides = overrides
        .where((o) =>
            o.studentId == studentId &&
            o.overrideType == OverrideType.add &&
            o.status != OverrideStatus.canceled &&
            o.replacementClassDateTime != null &&
            o.replacementClassDateTime!.isAfter(dateStart) &&
            o.replacementClassDateTime!.isBefore(dateEnd))
        .toList();

    final filtered = dailyRecords.where((record) {
      final isAddRecord = addOverrides.any(
          (o) => sameMinute(o.replacementClassDateTime!, record.classDateTime));
      return !isAddRecord; // 추가수업 기록은 제외 → 하단 밑줄은 순수 예정 수업만
    }).toList();

    return filtered;
  }

  /// 출석 기록을 기반으로 표시할 색상을 결정합니다
  Future<Color?> _determineAttendanceColor(
      List<AttendanceRecord> records) async {
    if (records.isEmpty) return null;

    // 학생의 지각 기준 시간을 가져옵니다
    final paymentInfo = await _getStudentPaymentInfo();
    final lateDurationMinutes = paymentInfo?.latenessThreshold ?? 10; // 기본 10분

    // ✅ 시간기록 다이얼로그와 동일 판정 로직으로 통일
    final now = DateTime.now();
    bool hasAbsent = false;
    bool hasLate = false;
    bool hasEarlyLeave = false;
    bool hasPresent = false;
    bool hasPlanned = false;

    for (final record in records) {
      final result = judgeAttendanceResult(
        record: record,
        now: now,
        latenessThresholdMinutes: lateDurationMinutes,
      );
      switch (result) {
        case AttendanceResult.absent:
          hasAbsent = true;
          break;
        case AttendanceResult.late:
          hasLate = true;
          break;
        case AttendanceResult.earlyLeave:
          hasEarlyLeave = true;
          break;
        case AttendanceResult.completed:
        case AttendanceResult.arrived:
        case AttendanceResult.present:
          hasPresent = true;
          break;
        case AttendanceResult.planned:
          hasPlanned = true;
          break;
      }
    }

    // 우선순위: 결석 > 지각 > 조퇴 > 출석 > 예정
    if (hasAbsent) return _colorAbsent;
    if (hasLate) return _colorLate;
    if (hasEarlyLeave) return _colorEarlyLeave;
    if (hasPresent) return _colorPresent;
    if (hasPlanned) return _colorPlanned;
    return null;
  }

  /// 해당 학생의 결제 정보를 가져옵니다
  Future<StudentPaymentInfo?> _getStudentPaymentInfo() async {
    return DataManager.instance.getStudentPaymentInfo(studentId);
  }
}

/// 다중 학생의 출석 상태를 표시하는 컴포넌트
class MultiStudentAttendanceIndicator extends StatelessWidget {
  final List<String> studentIds;
  final DateTime date;
  final double width;
  final double thickness;
  final double spacing;

  const MultiStudentAttendanceIndicator({
    Key? key,
    required this.studentIds,
    required this.date,
    this.width = 8.0,
    this.thickness = 2.5,
    this.spacing = 2.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (studentIds.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: studentIds
          .map((studentId) => Padding(
                padding: EdgeInsets.only(right: spacing),
                child: AttendanceIndicator(
                  studentId: studentId,
                  date: date,
                  width: width,
                  thickness: thickness,
                ),
              ))
          .toList(),
    );
  }
}

/// 출석 상태 요약을 표시하는 컴포넌트 (레전드)
class AttendanceLegend extends StatelessWidget {
  final bool showTitle;
  final double iconSize;
  final double fontSize;

  const AttendanceLegend({
    Key? key,
    this.showTitle = true,
    this.iconSize = 16.0,
    this.fontSize = 12.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              '출석 상태',
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize + 2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LegendItem(
              color: AttendanceIndicator._colorPresent,
              label: '정상',
              iconSize: iconSize,
              fontSize: fontSize,
            ),
            const SizedBox(width: 12),
            _LegendItem(
              color: AttendanceIndicator._colorLate,
              label: '지각',
              iconSize: iconSize,
              fontSize: fontSize,
            ),
            const SizedBox(width: 12),
            _LegendItem(
              color: AttendanceIndicator._colorAbsent,
              label: '결석',
              iconSize: iconSize,
              fontSize: fontSize,
            ),
          ],
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final double iconSize;
  final double fontSize;

  const _LegendItem({
    required this.color,
    required this.label,
    required this.iconSize,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: iconSize,
          height: iconSize * 0.25,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(iconSize * 0.125),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white70,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
