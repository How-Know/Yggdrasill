import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart';

import '../models/operating_hours.dart';
import '../models/student_time_block.dart';
import 'data_manager.dart';

enum TimetableExcelExportStatus { saved, cancelled, failed }

class TimetableExcelExportResult {
  final TimetableExcelExportStatus status;
  final String? path;
  final String? message;

  const TimetableExcelExportResult._({
    required this.status,
    this.path,
    this.message,
  });

  const TimetableExcelExportResult.saved(String savedPath)
      : this._(status: TimetableExcelExportStatus.saved, path: savedPath);

  const TimetableExcelExportResult.cancelled()
      : this._(status: TimetableExcelExportStatus.cancelled);

  const TimetableExcelExportResult.failed(String failureMessage)
      : this._(
          status: TimetableExcelExportStatus.failed,
          message: failureMessage,
        );
}

class TimetableExcelExportService {
  static const List<String> _weekdayLabels = <String>[
    '월',
    '화',
    '수',
    '목',
    '금',
    '토',
    '일',
  ];

  static Future<TimetableExcelExportResult> exportWeekTimetable({
    required DateTime selectedDate,
    required List<OperatingHours> operatingHours,
    required bool includeAllSheet,
    required Set<int> selectedDayIndices,
  }) async {
    if (!includeAllSheet && selectedDayIndices.isEmpty) {
      return const TimetableExcelExportResult.failed(
        '내보낼 시트를 하나 이상 선택해 주세요.',
      );
    }

    final List<int> dayIndices = selectedDayIndices
        .where((day) => day >= 0 && day <= 6)
        .toList()
      ..sort();

    final List<_TimeSlot> timeSlots = _generateTimeSlots(operatingHours);
    if (timeSlots.isEmpty) {
      return const TimetableExcelExportResult.failed(
        '운영시간이 설정되지 않아 시간표를 내보낼 수 없습니다.',
      );
    }

    try {
      final DateTime weekStart = _weekMonday(selectedDate);
      final DataManager dm = DataManager.instance;
      final List<StudentTimeBlock> weeklyBlocks =
          dm.getStudentTimeBlocksForWeek(weekStart);
      final Map<String, String> studentNameById = <String, String>{
        for (final student in dm.students)
          student.student.id: student.student.name,
      };

      final Map<String, Set<String>> occupancyBySlot = <String, Set<String>>{};
      final Map<String, SplayTreeSet<String>> startNamesBySlot =
          <String, SplayTreeSet<String>>{};

      for (final StudentTimeBlock block in weeklyBlocks) {
        if (block.dayIndex < 0 || block.dayIndex > 6) continue;
        if (!(block.number == null || block.number == 1)) continue;

        final DateTime dayDate = weekStart.add(Duration(days: block.dayIndex));
        if (!_isBlockActiveOnDate(block, dayDate)) continue;
        if (dm.isStudentPausedOn(block.studentId, dayDate)) continue;

        final int startMinute = block.startHour * 60 + block.startMinute;
        final int durationMinute = math.max(block.duration.inMinutes, 0);
        if (durationMinute <= 0) continue;
        final int endMinute = startMinute + durationMinute;

        // 전체 시트(정원) 계산: 수업 지속 시간 전체 슬롯에 인원수 반영
        for (int minute = startMinute; minute < endMinute; minute += 30) {
          final String occupancyKey = _slotKey(block.dayIndex, minute);
          occupancyBySlot
              .putIfAbsent(occupancyKey, () => <String>{})
              .add(block.studentId);
        }

        // 요일 시트 계산: 등원 시작시간 기준으로만 학생명 반영
        final String startKey = _slotKey(block.dayIndex, startMinute);
        final String studentName =
            studentNameById[block.studentId] ?? block.studentId;
        startNamesBySlot
            .putIfAbsent(startKey, () => SplayTreeSet<String>())
            .add(studentName);
      }

      final Excel excel = Excel.createExcel();
      final List<String> targetSheetNames = <String>[
        if (includeAllSheet) '전체',
        for (final int day in dayIndices) _weekdayLabels[day],
      ];

      if (targetSheetNames.isEmpty) {
        return const TimetableExcelExportResult.failed(
          '내보낼 시트를 하나 이상 선택해 주세요.',
        );
      }

      final String? defaultSheetName = excel.getDefaultSheet();
      if (defaultSheetName != null &&
          defaultSheetName != targetSheetNames.first) {
        excel.rename(defaultSheetName, targetSheetNames.first);
      }

      if (includeAllSheet) {
        final Sheet allSheet = excel['전체'];
        _buildAllSheet(
          sheet: allSheet,
          weekStart: weekStart,
          timeSlots: timeSlots,
          occupancyBySlot: occupancyBySlot,
        );
      }

      for (final int dayIndex in dayIndices) {
        final Sheet daySheet = excel[_weekdayLabels[dayIndex]];
        _buildDaySheet(
          sheet: daySheet,
          dayIndex: dayIndex,
          timeSlots: timeSlots,
          startNamesBySlot: startNamesBySlot,
        );
      }

      final List<int>? bytes = excel.encode();
      if (bytes == null || bytes.isEmpty) {
        return const TimetableExcelExportResult.failed(
          '엑셀 파일 생성에 실패했습니다.',
        );
      }

      final DateTime weekEnd = weekStart.add(const Duration(days: 6));
      final String suggestedName =
          '시간표_${_dateCode(weekStart)}_${_dateCode(weekEnd)}.xlsx';
      final FileSaveLocation? saveLocation = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'Excel', extensions: <String>['xlsx']),
        ],
      );
      if (saveLocation == null) {
        return const TimetableExcelExportResult.cancelled();
      }

      String outputPath = saveLocation.path;
      if (!outputPath.toLowerCase().endsWith('.xlsx')) {
        outputPath = '$outputPath.xlsx';
      }

      await File(outputPath).writeAsBytes(bytes, flush: true);
      return TimetableExcelExportResult.saved(outputPath);
    } catch (e) {
      return TimetableExcelExportResult.failed('엑셀 내보내기에 실패했습니다: $e');
    }
  }

  static void _buildAllSheet({
    required Sheet sheet,
    required DateTime weekStart,
    required List<_TimeSlot> timeSlots,
    required Map<String, Set<String>> occupancyBySlot,
  }) {
    _writeText(sheet, row: 0, col: 0, text: '요일');
    sheet.setColumnWidth(0, 16);

    for (int timeIdx = 0; timeIdx < timeSlots.length; timeIdx++) {
      final _TimeSlot slot = timeSlots[timeIdx];
      _writeText(
        sheet,
        row: 0,
        col: timeIdx + 1,
        text: slot.label,
      );
      sheet.setColumnWidth(timeIdx + 1, 10);
    }

    for (int day = 0; day < 7; day++) {
      final DateTime dayDate = weekStart.add(Duration(days: day));
      _writeText(
        sheet,
        row: day + 1,
        col: 0,
        text: '${_weekdayLabels[day]} (${dayDate.month}/${dayDate.day})',
      );

      for (int timeIdx = 0; timeIdx < timeSlots.length; timeIdx++) {
        final _TimeSlot slot = timeSlots[timeIdx];
        final int count =
            occupancyBySlot[_slotKey(day, slot.totalMinutes)]?.length ?? 0;
        _writeInt(sheet, row: day + 1, col: timeIdx + 1, value: count);
      }
    }
  }

  static void _buildDaySheet({
    required Sheet sheet,
    required int dayIndex,
    required List<_TimeSlot> timeSlots,
    required Map<String, SplayTreeSet<String>> startNamesBySlot,
  }) {
    _writeText(sheet, row: 0, col: 0, text: '시간');
    _writeText(sheet, row: 1, col: 0, text: '학생명');
    sheet.setColumnWidth(0, 12);

    final CellStyle namesCellStyle = CellStyle(
      textWrapping: TextWrapping.WrapText,
      horizontalAlign: HorizontalAlign.Left,
      verticalAlign: VerticalAlign.Top,
    );

    int maxNameCount = 1;
    for (int timeIdx = 0; timeIdx < timeSlots.length; timeIdx++) {
      final _TimeSlot slot = timeSlots[timeIdx];
      final int col = timeIdx + 1;
      sheet.setColumnWidth(col, 18);
      _writeText(sheet, row: 0, col: col, text: slot.label);

      final SplayTreeSet<String> names =
          startNamesBySlot[_slotKey(dayIndex, slot.totalMinutes)] ??
              SplayTreeSet<String>();
      maxNameCount = math.max(maxNameCount, names.length);

      final String joinedNames = names.join('\n');
      final Data cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 1),
      );
      cell.value = TextCellValue(joinedNames);
      cell.cellStyle = namesCellStyle;
    }

    final double rowHeight = (maxNameCount * 18 + 16).toDouble();
    sheet.setRowHeight(1, rowHeight.clamp(36.0, 320.0));
  }

  static void _writeText(
    Sheet sheet, {
    required int row,
    required int col,
    required String text,
  }) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value = TextCellValue(text);
  }

  static void _writeInt(
    Sheet sheet, {
    required int row,
    required int col,
    required int value,
  }) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value = IntCellValue(value);
  }

  static List<_TimeSlot> _generateTimeSlots(
      List<OperatingHours> operatingHours) {
    if (operatingHours.isEmpty) return const <_TimeSlot>[];

    int minMinute = 24 * 60;
    int maxMinute = 0;

    for (final OperatingHours hours in operatingHours) {
      final int start = hours.startHour * 60 + hours.startMinute;
      final int end = hours.endHour * 60 + hours.endMinute;
      if (start < minMinute) minMinute = start;
      if (end > maxMinute) maxMinute = end;
    }

    if (minMinute >= maxMinute) return const <_TimeSlot>[];

    final List<_TimeSlot> slots = <_TimeSlot>[];
    for (int minute = minMinute; minute < maxMinute; minute += 30) {
      slots.add(_TimeSlot(totalMinutes: minute));
    }
    return slots;
  }

  static DateTime _weekMonday(DateTime date) {
    final DateTime normalized = DateTime(date.year, date.month, date.day);
    final DateTime monday =
        normalized.subtract(Duration(days: normalized.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  static bool _isBlockActiveOnDate(
      StudentTimeBlock block, DateTime targetDate) {
    final DateTime target =
        DateTime(targetDate.year, targetDate.month, targetDate.day);
    final DateTime start = DateTime(
        block.startDate.year, block.startDate.month, block.startDate.day);
    final DateTime? end = block.endDate == null
        ? null
        : DateTime(
            block.endDate!.year, block.endDate!.month, block.endDate!.day);
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }

  static String _slotKey(int dayIndex, int totalMinutes) {
    return '$dayIndex-$totalMinutes';
  }

  static String _dateCode(DateTime date) {
    final String yy = date.year.toString().padLeft(4, '0');
    final String mm = date.month.toString().padLeft(2, '0');
    final String dd = date.day.toString().padLeft(2, '0');
    return '$yy$mm$dd';
  }
}

class _TimeSlot {
  final int totalMinutes;

  const _TimeSlot({required this.totalMinutes});

  int get hour => totalMinutes ~/ 60;
  int get minute => totalMinutes % 60;
  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
