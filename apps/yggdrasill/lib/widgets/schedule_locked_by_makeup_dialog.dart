import 'package:flutter/material.dart';
import '../main.dart';
import '../screens/timetable/views/makeup_view.dart';
import '../services/data_manager.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtYmdHm(DateTime d) =>
    '${d.year}.${_two(d.month)}.${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// 보강(Replace, planned) 때문에 시간표 수정/삭제가 막혔을 때 안내 다이얼로그.
Future<void> showScheduleLockedByMakeupDialog(
  BuildContext context,
  ScheduleLockedByMakeupException e, {
  bool useRoot = true,
}) async {
  final ctx = useRoot ? rootNavigatorKey.currentContext ?? context : context;
  final ov = e.blockingOverride;

  String? studentName;
  if (ov != null) {
    try {
      final s = DataManager.instance.students.firstWhere(
        (s) => s.student.id == ov.studentId,
        orElse: () => DataManager.instance.students.first,
      );
      if (s.student.id == ov.studentId) studentName = s.student.name;
    } catch (_) {}
  }

  final title = (studentName == null || studentName.trim().isEmpty)
      ? '보강 예약으로 인해 변경할 수 없습니다'
      : '$studentName · 보강 예약으로 인해 변경할 수 없습니다';

  final createdAt = ov?.createdAt;
  final original = ov?.originalClassDateTime;
  final replacement = ov?.replacementClassDateTime;

  final lines = <String>[
    '해당 수업은 보강이 예약되어 있어 현재 작업을 진행할 수 없습니다.',
    '보강을 먼저 취소/처리한 뒤 다시 시도해주세요.',
  ];
  if (replacement != null) {
    lines.add('');
    lines.add('보강 일정: ${_fmtYmdHm(replacement)}');
  }
  if (original != null) {
    lines.add('원본 일정: ${_fmtYmdHm(original)}');
  }
  if (createdAt != null) {
    lines.add('보강 예약 생성: ${_fmtYmdHm(createdAt)}');
  }

  await showDialog<void>(
    context: ctx,
    barrierDismissible: true,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: const Color(0xFF0B1112),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF223131)),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Color(0xFFEAF2F2),
            fontWeight: FontWeight.w900,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            lines.join('\n'),
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              // 보강 관리 열기
              await showDialog<void>(
                context: ctx,
                barrierColor: Colors.black54,
                builder: (context) {
                  return Dialog(
                    backgroundColor: const Color(0xFF1F1F1F),
                    insetPadding: const EdgeInsets.fromLTRB(42, 42, 42, 32),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: const SizedBox(
                      width: 770,
                      height: 760,
                      child: MakeupView(),
                    ),
                  );
                },
              );
            },
            child: const Text(
              '보강 관리',
              style: TextStyle(color: Color(0xFF1976D2), fontWeight: FontWeight.w800),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              '확인',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      );
    },
  );
}

