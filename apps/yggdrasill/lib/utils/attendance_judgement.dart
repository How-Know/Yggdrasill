import 'package:flutter/material.dart';

import '../models/attendance_record.dart';

/// 출결 결과(단일 값) 판정 로직.
///
/// - 다른 UI(출석체크/리포트/리스트)에서 재사용하기 위해 "순수 로직"으로 분리.
/// - 조퇴 판정: 실제 출석 시간(하원-등원)이 기준 수업 시간(종료-시작)의 60% 미만이면 조퇴.
/// - 지각 판정: 등원 시간이 시작+latenessThresholdMinutes 이후면 지각.
enum AttendanceResult {
  planned, // 예정(미래/오늘)
  noShow, // 미출석(과거 예정)
  absent, // 결석(명시적 불참)
  earlyLeave, // 조퇴(60% 미만 출석 후 하원)
  late, // 지각
  completed, // 완료(등원+하원)
  arrived, // 등원(등원만)
  present, // 출석(시간 기록 없음/불완전)
}

extension AttendanceResultX on AttendanceResult {
  String get label {
    switch (this) {
      case AttendanceResult.planned:
        return '예정';
      case AttendanceResult.noShow:
        return '미출석';
      case AttendanceResult.absent:
        return '결석';
      case AttendanceResult.earlyLeave:
        return '조퇴';
      case AttendanceResult.late:
        return '지각';
      case AttendanceResult.completed:
        return '완료';
      case AttendanceResult.arrived:
        return '등원';
      case AttendanceResult.present:
        return '출석';
    }
  }

  /// UI 배지용 권장 색상
  Color get badgeColor {
    switch (this) {
      case AttendanceResult.completed:
        return const Color(0xFF33A373);
      case AttendanceResult.arrived:
        return const Color(0xFF223131);
      case AttendanceResult.late:
        return const Color(0xFFF2B45B);
      case AttendanceResult.earlyLeave:
        return const Color(0xFF8E6CEF);
      case AttendanceResult.absent:
        return const Color(0xFFE57373);
      case AttendanceResult.noShow:
        return const Color(0xFF5B4B2B);
      case AttendanceResult.planned:
        return const Color(0xFF223131);
      case AttendanceResult.present:
        return const Color(0xFF223131);
    }
  }
}

bool _isPurePlanned(AttendanceRecord r) {
  return r.isPlanned == true &&
      !r.isPresent &&
      r.arrivalTime == null &&
      r.departureTime == null;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

AttendanceResult judgeAttendanceResult({
  required AttendanceRecord record,
  required DateTime now,
  int latenessThresholdMinutes = 10,
  double earlyLeaveRatio = 0.6,
}) {
  // 1) 순수 예정(planned) 레코드: 날짜에 따라 예정/미출석으로 분기
  if (_isPurePlanned(record)) {
    final today = _dateOnly(now);
    final d = _dateOnly(record.classDateTime);
    // "오늘 이전"은 미출석(=노쇼), 오늘 포함 미래는 예정
    return d.isBefore(today) ? AttendanceResult.noShow : AttendanceResult.planned;
  }

  // 2) 명시적 결석
  if (!record.isPresent) {
    return AttendanceResult.absent;
  }

  final start = record.classDateTime;
  final end = record.classEndTime;
  final arrival = record.arrivalTime;
  final departure = record.departureTime;

  // 3) 출석 처리 되었으나 등원 시간이 없는 경우(데이터 불완전)
  if (arrival == null) {
    return AttendanceResult.present;
  }

  final lateThreshold = start.add(Duration(minutes: latenessThresholdMinutes));
  final isLate = arrival.isAfter(lateThreshold);

  // 4) 하원 기록이 있는 경우: 조퇴/완료/지각 판정
  if (departure != null) {
    final scheduled = end.difference(start).inSeconds;
    final attended = departure.difference(arrival).inSeconds;

    // 조퇴: 실제 출석 시간이 기준 수업 시간의 earlyLeaveRatio 미만
    if (scheduled > 0 && attended >= 0) {
      final ratio = attended / scheduled;
      if (ratio < earlyLeaveRatio) {
        return AttendanceResult.earlyLeave;
      }
    }

    return isLate ? AttendanceResult.late : AttendanceResult.completed;
  }

  // 5) 등원만 기록된 경우: 지각/등원
  return isLate ? AttendanceResult.late : AttendanceResult.arrived;
}


