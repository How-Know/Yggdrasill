import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/student.dart';
import '../../../services/data_manager.dart';
import '../../../theme/ygg_semantic_colors.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../widgets/student_registration_dialog.dart';

Future<void> editStudentFromDetail({
  required BuildContext context,
  required Student student,
}) async {
  await StudentRegistrationDialog.show(
    context: context,
    student: student,
    onSave: (updated, basicInfo) async {
      await DataManager.instance.updateStudent(updated, basicInfo);
      if (!context.mounted) return;
      showAppSnackBar(context, '학생 정보가 수정되었습니다.', useRoot: true);
    },
    groups: DataManager.instance.groups,
  );
}

Future<void> toggleStudentPauseFromDetail({
  required BuildContext context,
  required Student student,
  required Future<void> Function() onRefresh,
}) async {
  final activePause = DataManager.instance.getOpenPauseForStudent(student.id);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  final ThemeData pickerTheme = Theme.of(context).copyWith(
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF33A373),
      surface: Color(0xFF15171C),
      onSurface: Colors.white70,
    ),
    dialogBackgroundColor: context.yggSurfaceBase,
  );

  if (activePause != null) {
    final picked = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: activePause.pausedFrom.isAfter(today)
          ? today
          : activePause.pausedFrom,
      lastDate: DateTime(today.year + 2, 12, 31),
      builder: (context, child) => Theme(
        data: pickerTheme,
        child: child!,
      ),
    );
    if (picked == null) return;
    try {
      await DataManager.instance.resumeStudent(
        studentId: student.id,
        resumeDateLocal: picked,
      );
      if (!context.mounted) return;
      await onRefresh();
      if (!context.mounted) return;
      showAppSnackBar(context, '등원 처리되었습니다.', useRoot: true);
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(context, '등원 처리 실패: $e', useRoot: true);
    }
    return;
  }

  DateTime? from;
  DateTime? to;
  final noteController = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        backgroundColor: const Color(0xFF232326),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('휴원', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '휴원 기간에는 예정 수업이 생성되지 않고 등원이 막힙니다.\n예상 등원일은 메모이며, 실제 종료일은 등원 처리할 때 정해집니다.',
                style: TextStyle(color: Colors.white70, height: 1.35),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: today,
                          firstDate: DateTime(2018, 1, 1),
                          lastDate: DateTime(today.year + 2, 12, 31),
                          builder: (context, child) => Theme(
                            data: pickerTheme,
                            child: child!,
                          ),
                        );
                        if (picked == null) return;
                        setLocal(() => from = picked);
                      },
                      child: Text(
                        from == null
                            ? '휴원 시작일 선택'
                            : '시작: ${DateFormat('yyyy.MM.dd').format(from!)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final base = from ?? today;
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: base,
                          firstDate: base,
                          lastDate: DateTime(today.year + 2, 12, 31),
                          builder: (context, child) => Theme(
                            data: pickerTheme,
                            child: child!,
                          ),
                        );
                        if (picked == null) return;
                        setLocal(() => to = picked);
                      },
                      child: Text(
                        to == null
                            ? '예상 등원일(메모, 선택)'
                            : '예상: ${DateFormat('yyyy.MM.dd').format(to!)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '메모(선택)',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF3A3F44)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              '휴원',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) {
    noteController.dispose();
    return;
  }
  final start = from ?? today;
  try {
    await DataManager.instance.pauseStudent(
      studentId: student.id,
      pausedFromLocal: start,
      pausedToLocal: to,
      note: noteController.text.trim(),
    );
    if (!context.mounted) return;
    await onRefresh();
    if (!context.mounted) return;
    showAppSnackBar(context, '휴원 처리되었습니다.', useRoot: true);
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(context, '휴원 처리 실패: $e', useRoot: true);
  } finally {
    noteController.dispose();
  }
}

Future<void> withdrawStudentFromDetail({
  required BuildContext context,
  required Student student,
  required VoidCallback onClosed,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF232326),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('퇴원', style: TextStyle(color: Colors.white)),
      content: Text(
        '${student.name} 학생을 퇴원(삭제) 처리하시겠습니까?\n\n'
        '퇴원 처리 시 학생 정보는 아카이브에 최대 1년간 보관됩니다.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(
            '퇴원',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await DataManager.instance.deleteStudent(student.id);
    if (!context.mounted) return;
    showAppSnackBar(context, '퇴원 처리되었습니다.', useRoot: true);
    onClosed();
  } catch (e) {
    if (!context.mounted) return;
    final s = e.toString();
    if (s.contains('archive_student') || s.contains('student_archives')) {
      showAppSnackBar(
        context,
        '아카이브 생성 실패로 퇴원을 중단했습니다. (서버 마이그레이션 적용 필요)\n$s',
        useRoot: true,
      );
    } else {
      showAppSnackBar(context, '퇴원 처리 실패: $e', useRoot: true);
    }
  }
}
