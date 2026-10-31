import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../main.dart' show rootNavigatorKey;
import '../services/data_manager.dart';
import '../services/todo_sheet_snapshot_service.dart';
import 'app_dialog_action_button.dart';
import 'bottom_dialog.dart';
import 'dialog_tokens.dart';

/// 학부모 알림장 주소. 하원 창과 알림톡 버튼이 같은 주소를 쓴다.
///
/// 알림톡 템플릿에는 이 주소 뒤에 `?t=#{알림장토큰}`을 넣는다.
const String kTodoSheetSharePreviewOrigin = 'https://mneme.co.kr/s';

String todoSheetSharePreviewUrl(String token) =>
    '$kTodoSheetSharePreviewOrigin?t=$token';

/// 하원 창이 뜨는 동안 알림장 페이지를 한 번 열어 둔다.
void warmTodoSheetSharePreview(String token) {
  final value = token.trim();
  if (value.isEmpty) return;
  unawaited(() async {
    try {
      await http
          .get(Uri.parse(todoSheetSharePreviewUrl(value)))
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }());
}

bool studentAllowsTodoSheetShareLink(String studentId) {
  for (final row in DataManager.instance.students) {
    if (row.student.id == studentId) {
      return row.basicInfo.todoSheetAlimtalkConsent;
    }
  }
  return false;
}

final Set<String> _shareLinkOwnedAttendanceIds = <String>{};
final Map<String, DateTime> _shareLinkOwnedStudents = <String, DateTime>{};

/// 이 PC에서 직접 하원한 출결. 스탠바이미 하원 감지와 창이 겹치지 않게 한다.
void ownTodoSheetShareLinkAttendance(String attendanceId) {
  final id = attendanceId.trim();
  if (id.isEmpty) return;
  _shareLinkOwnedAttendanceIds.add(id);
}

void ownTodoSheetShareLinkStudent(String studentId) {
  final id = studentId.trim();
  if (id.isEmpty) return;
  _shareLinkOwnedStudents[id] = DateTime.now();
}

bool todoSheetShareLinkOwnedByThisApp(
  String attendanceId, {
  String? studentId,
}) {
  if (_shareLinkOwnedAttendanceIds.contains(attendanceId.trim())) return true;
  final student = (studentId ?? '').trim();
  final ownedAt = _shareLinkOwnedStudents[student];
  if (ownedAt == null) return false;
  return DateTime.now().difference(ownedAt) < const Duration(minutes: 2);
}

/// 알림장 수신에 동의한 학생만, 하원으로 고정된 알림장 주소를 보여 준다.
///
/// 알림톡은 보내지 않는다. 링크 생성에 실패해도 하원 자체는 되돌리지 않는다.
Future<void> showTodoSheetShareLinkAfterDeparture({
  required BuildContext context,
  required String studentId,
  required String studentName,
  required String snapshotId,
}) async {
  if (!studentAllowsTodoSheetShareLink(studentId)) return;
  final key = snapshotId.trim();
  if (key.isEmpty) return;
  String token;
  try {
    token = await TodoSheetSnapshotService.instance.ensureShareLink(key);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('알림장 링크를 만들지 못했어요: $error')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  warmTodoSheetSharePreview(token);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(
      alpha: BottomDialogMetrics.barrierOpacity,
    ),
    builder: (dialogContext) {
      return _TodoSheetShareLinkDialog(
        studentName: studentName,
        url: todoSheetSharePreviewUrl(token),
      );
    },
  );
}

/// 스탠바이미 하원처럼 이 PC가 직접 열지 않은 하원에서 같은 창을 띄운다.
Future<void> showTodoSheetShareLinkOnRoot({
  required String studentId,
  required String studentName,
  required String snapshotId,
}) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  await showTodoSheetShareLinkAfterDeparture(
    context: context,
    studentId: studentId,
    studentName: studentName,
    snapshotId: snapshotId,
  );
}

void reportTodoSheetShareLinkFailure(String message) {
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

class _TodoSheetShareLinkDialog extends StatefulWidget {
  const _TodoSheetShareLinkDialog({
    required this.studentName,
    required this.url,
  });

  final String studentName;
  final String url;

  @override
  State<_TodoSheetShareLinkDialog> createState() =>
      _TodoSheetShareLinkDialogState();
}

class _TodoSheetShareLinkDialogState extends State<_TodoSheetShareLinkDialog> {
  var _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = YggDialogColors.of(context);
    final name = widget.studentName.trim().isEmpty ? '학생' : widget.studentName.trim();
    return BottomDialog(
      icon: Icons.link_rounded,
      title: '알림장 링크',
      shrinkWrap: true,
      preferredWidth: 520,
      onClose: () => Navigator.of(context).pop(),
      footer: Align(
        alignment: Alignment.centerRight,
        child: AppDialogConfirmButton(
          label: _copied ? '복사됨' : '복사',
          onPressed: _copy,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BottomDialogLargeText('$name 알림장'),
          const SizedBox(height: BottomDialogMetrics.largeToMediumGap),
          const BottomDialogMediumText(
            '이 컴퓨터가 켜져 있을 때만 열립니다.',
          ),
          const SizedBox(height: BottomDialogMetrics.beforeActionsGap),
          BottomDialogCard(
            child: SelectableText(
              widget.url,
              style: TextStyle(
                color: colors.text,
                fontSize: BottomDialogMetrics.mediumFontSize,
                fontWeight: FontWeight.w600,
                height: 1.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
