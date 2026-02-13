import 'package:flutter/material.dart';

import '../models/student_flow.dart';
import '../models/textbook_drag_payload.dart';
import '../services/data_manager.dart';
import 'dialog_tokens.dart';
import 'flow_setup_dialog.dart';

Future<void> linkDraggedTextbookToStudentFlow({
  required BuildContext context,
  required String studentId,
  required TextbookDragPayload payload,
}) async {
  final String bookId = payload.bookId.trim();
  final String bookName = payload.bookName.trim();
  final String gradeLabel = payload.gradeLabel.trim();

  if (bookId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('교재 정보가 올바르지 않아 연결할 수 없습니다.')),
    );
    return;
  }
  if (gradeLabel.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('교재의 과정(학년) 정보가 없어 연결할 수 없습니다.')),
    );
    return;
  }

  try {
    final enabledFlows = await ensureEnabledFlowsForHomework(context, studentId);
    if (!context.mounted) return;
    if (enabledFlows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('플로우가 설정되지 않아 교재를 연결할 수 없습니다.')),
      );
      return;
    }

    final selectedFlow = await _pickFlowForTextbookLink(
      context,
      enabledFlows,
    );
    if (!context.mounted || selectedFlow == null) return;

    final rows = await DataManager.instance.loadFlowTextbookLinks(selectedFlow.id);
    if (!context.mounted) return;

    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final row in rows) {
      final bid = (row['book_id'] as String?)?.trim() ?? '';
      final gl = (row['grade_label'] as String?)?.trim() ?? '';
      if (bid.isEmpty || gl.isEmpty) continue;
      final key = '$bid|$gl';
      if (!seen.add(key)) continue;
      merged.add({
        'book_id': bid,
        'grade_label': gl,
        'book_name': (row['book_name'] as String?)?.trim() ?? '',
      });
    }

    final droppedKey = '$bookId|$gradeLabel';
    if (!seen.add(droppedKey)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이미 연결된 교재입니다.')),
      );
      return;
    }

    merged.add({
      'book_id': bookId,
      'grade_label': gradeLabel,
      'book_name': bookName,
    });

    await DataManager.instance.saveFlowTextbookLinks(selectedFlow.id, merged);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${bookName.isEmpty ? '선택한 교재' : bookName}를 ${selectedFlow.name} 플로우에 연결했습니다.',
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('교재 연결 중 오류가 발생했습니다: $e')),
    );
  }
}

Future<StudentFlow?> _pickFlowForTextbookLink(
  BuildContext context,
  List<StudentFlow> enabledFlows,
) async {
  if (enabledFlows.isEmpty) return null;
  if (enabledFlows.length == 1) return enabledFlows.first;

  StudentFlow selected = enabledFlows.first;
  return showDialog<StudentFlow>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              '플로우 선택',
              style: TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w900,
              ),
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '연결할 플로우를 선택하세요.',
                      style: TextStyle(color: kDlgTextSub),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: enabledFlows.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: kDlgBorder, height: 1),
                      itemBuilder: (ctx, i) {
                        final flow = enabledFlows[i];
                        return RadioListTile<String>(
                          value: flow.id,
                          groupValue: selected.id,
                          onChanged: (v) {
                            if (v == null) return;
                            setLocal(() => selected = flow);
                          },
                          activeColor: kDlgAccent,
                          fillColor: MaterialStateProperty.resolveWith<Color?>(
                            (states) => states.contains(MaterialState.selected)
                                ? kDlgAccent
                                : kDlgBorder,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          title: Text(
                            flow.name,
                            style: const TextStyle(
                              color: kDlgText,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('선택'),
              ),
            ],
          );
        },
      );
    },
  );
}
