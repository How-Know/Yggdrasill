import '../models/session_override.dart';
import '../models/student_time_block.dart';
import 'data_manager.dart';

/// 학생의 현재 수업 다음 회차 시작 시각을 시간표와 보강/변경 일정에서 계산한다.
///
/// 같은 `setId`의 연속 시간 블록은 한 수업으로 보고 첫 블록 시작 시각만
/// 반환한다. 이 구분이 없으면 현재 수업의 두 번째 블록이 숙제 검사 시각으로
/// 선택될 수 있다.
class NextClassStartResolver {
  const NextClassStartResolver._();

  static DateTime? next(
    String studentId, {
    DateTime? after,
  }) {
    final starts = upcoming(studentId, after: after, limit: 1);
    return starts.isEmpty ? null : starts.first;
  }

  static List<DateTime> upcoming(
    String studentId, {
    DateTime? after,
    int limit = 12,
  }) {
    final cutoff = after ?? DateTime.now();
    final dm = DataManager.instance;
    final candidates = <DateTime>[];
    final seen = <int>{};

    void add(DateTime value) {
      final local = value.toLocal();
      if (!local.isAfter(cutoff)) return;
      final minuteKey = DateTime(
        local.year,
        local.month,
        local.day,
        local.hour,
        local.minute,
      ).millisecondsSinceEpoch;
      if (seen.add(minuteKey)) candidates.add(local);
    }

    String dateTimeKey(DateTime value) {
      final local = value.toLocal();
      return '${local.year}-${local.month}-${local.day}-'
          '${local.hour}:${local.minute}';
    }

    final overrides = dm.getSessionOverridesForStudent(studentId);
    final hiddenOriginalKeys = <String>{};
    for (final override in overrides) {
      if (override.reason != OverrideReason.makeup ||
          override.status == OverrideStatus.canceled ||
          override.overrideType != OverrideType.replace) {
        continue;
      }
      final original = override.originalClassDateTime;
      if (original != null) hiddenOriginalKeys.add(dateTimeKey(original));
    }

    final blocks = dm.studentTimeBlocks
        .where((block) => block.studentId == studentId)
        .toList(growable: false);
    final cutoffDay = DateTime(cutoff.year, cutoff.month, cutoff.day);
    final weekStart = cutoffDay.subtract(Duration(days: cutoffDay.weekday - 1));

    for (var week = 0; week < 12; week++) {
      final blocksBySession = <String, List<StudentTimeBlock>>{};
      for (final block in blocks) {
        final day = weekStart.add(Duration(days: week * 7 + block.dayIndex));
        final dayOnly = DateTime(day.year, day.month, day.day);
        final startDate = DateTime(
          block.startDate.year,
          block.startDate.month,
          block.startDate.day,
        );
        final endDate = block.endDate == null
            ? null
            : DateTime(
                block.endDate!.year,
                block.endDate!.month,
                block.endDate!.day,
              );
        if (dayOnly.isBefore(startDate) ||
            (endDate != null && dayOnly.isAfter(endDate)) ||
            dm.isStudentPausedOn(studentId, dayOnly)) {
          continue;
        }
        final setId = (block.setId ?? '').trim();
        final sessionKey = setId.isEmpty
            ? '${dayOnly.millisecondsSinceEpoch}:single:${block.id}'
            : '${dayOnly.millisecondsSinceEpoch}:set:$setId';
        blocksBySession.putIfAbsent(sessionKey, () => []).add(block);
      }

      for (final sessionBlocks in blocksBySession.values) {
        sessionBlocks.sort((a, b) {
          final hourCompare = a.startHour.compareTo(b.startHour);
          return hourCompare != 0
              ? hourCompare
              : a.startMinute.compareTo(b.startMinute);
        });
        final first = sessionBlocks.first;
        final day = weekStart.add(Duration(days: week * 7 + first.dayIndex));
        final start = DateTime(
          day.year,
          day.month,
          day.day,
          first.startHour,
          first.startMinute,
        );
        if (!hiddenOriginalKeys.contains(dateTimeKey(start))) add(start);
      }
    }

    for (final override in overrides) {
      if (override.reason != OverrideReason.makeup ||
          override.status == OverrideStatus.canceled ||
          (override.overrideType != OverrideType.add &&
              override.overrideType != OverrideType.replace)) {
        continue;
      }
      final replacement = override.replacementClassDateTime;
      if (replacement == null) continue;
      final local = replacement.toLocal();
      if (dm.isStudentPausedOn(
        studentId,
        DateTime(local.year, local.month, local.day),
      )) {
        continue;
      }
      add(local);
    }

    candidates.sort();
    if (limit <= 0 || candidates.length <= limit) return candidates;
    return candidates.sublist(0, limit);
  }
}
