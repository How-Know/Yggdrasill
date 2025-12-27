import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

const Color _dlgBg = Color(0xFF0B1112);
const Color _dlgPanelBg = Color(0xFF10171A);
const Color _dlgFieldBg = Color(0xFF15171C);
const Color _dlgBorder = Color(0xFF223131);
const Color _dlgText = Color(0xFFEAF2F2);
const Color _dlgTextSub = Color(0xFF9FB3B3);
const Color _dlgAccent = Color(0xFF33A373);

class MemoCreateResult {
  final String text;
  /// 메모 카테고리(수동 선택)
  final String categoryKey; // schedule|consult
  const MemoCreateResult(this.text, {required this.categoryKey});
}

class MemoInputDialog extends StatefulWidget {
  final String? initialCategoryKey; // schedule|consult
  const MemoInputDialog({super.key, this.initialCategoryKey});

  @override
  State<MemoInputDialog> createState() => _MemoInputDialogState();
}

class _MemoInputDialogState extends State<MemoInputDialog> {
  final TextEditingController _controller = ImeAwareTextEditingController();
  bool _saving = false;
  String _categoryKey = 'schedule'; // schedule|consult

  @override
  void initState() {
    super.initState();
    final k = widget.initialCategoryKey;
    if (k == 'schedule' || k == 'consult') {
      _categoryKey = k!;
    } else {
      _categoryKey = 'schedule';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  InputDecoration _decoration({String? hintText}) => InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: _dlgTextSub),
        filled: true,
        fillColor: _dlgFieldBg,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _dlgBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _dlgAccent),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _dlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _dlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: const Text(
        '메모 추가',
        style: TextStyle(color: _dlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(color: _dlgBorder, height: 1),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('일정', style: TextStyle(fontWeight: FontWeight.w800)),
                    selected: _categoryKey == 'schedule',
                    onSelected: (_) => setState(() => _categoryKey = 'schedule'),
                    selectedColor: _dlgAccent,
                    backgroundColor: _dlgPanelBg,
                    labelStyle: TextStyle(color: _categoryKey == 'schedule' ? Colors.white : _dlgTextSub),
                    side: BorderSide(color: _categoryKey == 'schedule' ? _dlgAccent : _dlgBorder, width: _categoryKey == 'schedule' ? 2 : 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  ChoiceChip(
                    label: const Text('상담', style: TextStyle(fontWeight: FontWeight.w800)),
                    selected: _categoryKey == 'consult',
                    onSelected: (_) => setState(() => _categoryKey = 'consult'),
                    selectedColor: _dlgAccent,
                    backgroundColor: _dlgPanelBg,
                    labelStyle: TextStyle(color: _categoryKey == 'consult' ? Colors.white : _dlgTextSub),
                    side: BorderSide(color: _categoryKey == 'consult' ? _dlgAccent : _dlgBorder, width: _categoryKey == 'consult' ? 2 : 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 5,
              maxLines: 10,
              style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
              decoration: _decoration(hintText: '메모를 입력하세요'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: _dlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () {
                  setState(() => _saving = true);
                  Navigator.of(context).pop(
                    MemoCreateResult(_controller.text, categoryKey: _categoryKey),
                  );
                },
          style: FilledButton.styleFrom(
            backgroundColor: _dlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('저장', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}

enum MemoEditAction { save, delete }

class MemoEditResult {
  final MemoEditAction action;
  final String text;
  final DateTime? scheduledAt;
  const MemoEditResult(this.action, this.text, {this.scheduledAt});
}

class MemoEditDialog extends StatefulWidget {
  final String initial;
  final DateTime? initialScheduledAt;
  const MemoEditDialog({super.key, required this.initial, this.initialScheduledAt});

  @override
  State<MemoEditDialog> createState() => _MemoEditDialogState();
}

class _MemoEditDialogState extends State<MemoEditDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  DateTime? _scheduledAt;

  @override
  void initState() {
    super.initState();
    _controller = ImeAwareTextEditingController(text: widget.initial);
    _scheduledAt = widget.initialScheduledAt;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  InputDecoration _decoration() => InputDecoration(
        filled: true,
        fillColor: _dlgFieldBg,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _dlgBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _dlgAccent),
        ),
      );

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 2),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: _dlgAccent),
          dialogBackgroundColor: _dlgBg,
        ),
        child: child!,
      ),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? now),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(primary: _dlgAccent),
          dialogBackgroundColor: _dlgBg,
        ),
        child: child!,
      ),
    );
    if (pickedTime == null) return;
    setState(() {
      _scheduledAt = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime.hour, pickedTime.minute);
    });
  }

  String _scheduleLabel() {
    final s = _scheduledAt;
    if (s == null) return '일정 없음';
    final hh = s.hour.toString().padLeft(2, '0');
    final mm = s.minute.toString().padLeft(2, '0');
    return '${s.month}/${s.day} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _dlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _dlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: const Text(
        '메모 보기/수정',
        style: TextStyle(color: _dlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(color: _dlgBorder, height: 1),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 14,
              style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
              decoration: _decoration(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickSchedule,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(_scheduleLabel()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      backgroundColor: _dlgPanelBg,
                      side: const BorderSide(color: _dlgBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: () => setState(() => _scheduledAt = null),
                  tooltip: '일정 제거',
                  icon: const Icon(Icons.close, color: _dlgTextSub),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: _dlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(const MemoEditResult(MemoEditAction.delete, '')),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFB74C4C),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('삭제', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () {
                  setState(() => _saving = true);
                  Navigator.of(context).pop(MemoEditResult(MemoEditAction.save, _controller.text, scheduledAt: _scheduledAt));
                },
          style: FilledButton.styleFrom(
            backgroundColor: _dlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('저장', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}


