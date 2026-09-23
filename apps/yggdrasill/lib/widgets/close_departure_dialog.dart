import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/attendance_record.dart';
import '../services/data_manager.dart';
import 'dialog_tokens.dart';
import 'utility_glass_dialog_shell.dart';

/// 종료 전 미하원 확인.
///
/// `null`이면 종료를 취소한다. 빈 목록은 하원 없이 종료, 그 외는 선택한 기록만
/// 하원 처리한 뒤 종료한다.
Future<List<AttendanceRecord>?> showCloseDepartureDialog({
  required BuildContext context,
  required List<AttendanceRecord> records,
}) {
  return showDialog<List<AttendanceRecord>>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      final maxHeight = math.min(media.size.height * 0.72, 640.0);
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: UtilityGlassDialogShell(
          title: '종료',
          icon: Icons.logout_rounded,
          preferredWidth: 480,
          maxWidth: 480,
          maxHeight: maxHeight,
          onClose: () => Navigator.of(dialogContext).pop(),
          child: _CloseDepartureDialogBody(records: records),
        ),
      );
    },
  );
}

class _CloseDepartureDialogBody extends StatefulWidget {
  const _CloseDepartureDialogBody({required this.records});

  final List<AttendanceRecord> records;

  @override
  State<_CloseDepartureDialogBody> createState() =>
      _CloseDepartureDialogBodyState();
}

class _CloseDepartureDialogBodyState extends State<_CloseDepartureDialogBody> {
  late final Set<String> _selectedIds;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.records.map(_recordKey).toSet();
  }

  String _recordKey(AttendanceRecord record) {
    final id = (record.id ?? '').trim();
    if (id.isNotEmpty) return id;
    return '${record.studentId}|${record.classDateTime.toIso8601String()}';
  }

  String _studentName(String studentId) {
    for (final row in DataManager.instance.students) {
      if (row.student.id == studentId) {
        final name = row.student.name.trim();
        if (name.isNotEmpty) return name;
      }
    }
    return '이름 없는 학생';
  }

  String _hm(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _mdhm(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} ${_hm(local)}';
  }

  List<AttendanceRecord> get _selectedRecords {
    return widget.records
        .where((record) => _selectedIds.contains(_recordKey(record)))
        .toList(growable: false);
  }

  Future<void> _departAndClose() async {
    final selected = _selectedRecords;
    if (selected.isEmpty || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await DataManager.instance.closeMissingDepartures(selected);
      if (!mounted) return;
      Navigator.of(context).pop(selected);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '하원 처리에 실패했습니다. 다시 시도하거나 그냥 종료해 주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _selectedIds.length == widget.records.length;
    final noneSelected = _selectedIds.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '수업일 기준 이틀이 지난 미하원입니다. 선택한 기록만 수업일 다음날 자정으로 하원 처리한 뒤 종료합니다.',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.45,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            value: allSelected ? true : (noneSelected ? false : null),
            tristate: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: kDlgAccent,
            checkColor: Colors.white,
            side: const BorderSide(color: Color(0x66FFFFFF)),
            title: Text(
              '전체 선택 ${_selectedIds.length}/${widget.records.length}',
              style: const TextStyle(
                color: kDlgText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                decoration: TextDecoration.none,
              ),
            ),
            onChanged: _working
                ? null
                : (_) {
                    setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(widget.records.map(_recordKey));
                      }
                    });
                  },
          ),
          const Divider(
              height: 1, color: UtilityGlassDialogTokens.dividerColor),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: widget.records.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                color: UtilityGlassDialogTokens.dividerColor,
              ),
              itemBuilder: (context, index) {
                final record = widget.records[index];
                final key = _recordKey(record);
                final className = record.className.trim();
                final arrival = record.arrivalTime;
                final detail = [
                  if (className.isNotEmpty) className,
                  '수업 ${_mdhm(record.classDateTime)}',
                  if (arrival != null) '등원 ${_hm(arrival)}',
                ].join(' · ');
                return CheckboxListTile(
                  value: _selectedIds.contains(key),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: kDlgAccent,
                  checkColor: Colors.white,
                  side: const BorderSide(color: Color(0x66FFFFFF)),
                  title: Text(
                    _studentName(record.studentId),
                    style: const TextStyle(
                      color: kDlgText,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  subtitle: Text(
                    '$detail\n하원 기록 ${_mdhm(record.openSessionCapAt)}',
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  onChanged: _working
                      ? null
                      : (checked) {
                          setState(() {
                            if (checked == true) {
                              _selectedIds.add(key);
                            } else {
                              _selectedIds.remove(key);
                            }
                          });
                        },
                );
              },
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFFFB4B4),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _working
                      ? null
                      : () => Navigator.of(context).pop(
                            const <AttendanceRecord>[],
                          ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kDlgText,
                    side: const BorderSide(color: Color(0x33FFFFFF)),
                    minimumSize: const Size(0, 42),
                  ),
                  child: const Text('그냥 종료'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _working || noneSelected ? null : _departAndClose,
                  style: FilledButton.styleFrom(
                    backgroundColor: kDlgAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF2A4A3C),
                    minimumSize: const Size(0, 42),
                  ),
                  child: Text(_working ? '하원 처리 중...' : '하원 후 종료'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
