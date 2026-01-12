import 'package:flutter/material.dart';

import '../models/attendance_record.dart';

/// 출결 결과(단일 값) 판정 로직.
///
/// - 다른 UI(출석체크/리포트/리스트)에서 재사용하기 위해 "순수 로직"으로 분리.
/// - 조퇴 판정: 실제 출석 시간(하원-등원)이 기준 수업 시간(종료-시작)의 60% 미만이면 조퇴.
/// - 지각 판정: 등원 시간이 시작+latenessThresholdMinutes 이후면 지각.
enum AttendanceResult {
  planned, // 예정(미래/오늘)
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
        // 앱 톤에 맞게 조금 더 딥한 그린
        return const Color(0xFF2A9B6B);
      case AttendanceResult.arrived:
        return const Color(0xFF223131);
      case AttendanceResult.late:
        // 앱 톤에 맞게 덜 밝은 앰버
        return const Color(0xFFE2A64C);
      case AttendanceResult.earlyLeave:
        // 앱 톤에 맞게 덜 형광 느낌의 퍼플
        return const Color(0xFF7B62D3);
      case AttendanceResult.absent:
        // 앱 톤에 맞게 덜 밝은 레드
        return const Color(0xFFDA5A5A);
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
    // "오늘 이전"은 결석(미출석 포함), 오늘 포함 미래는 예정
    return d.isBefore(today) ? AttendanceResult.absent : AttendanceResult.planned;
  }

  // 2) 결석 판정(정합성 보강)
  // - legacy/동기화/일부 UI 경로에서 arrival/departure는 존재하지만 isPresent=false로 남는 경우가 있어
  //   시간 기록이 있으면 "출석"으로 간주한다.
  final bool effectivePresent =
      record.isPresent || record.arrivalTime != null || record.departureTime != null;
  if (!effectivePresent) {
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


