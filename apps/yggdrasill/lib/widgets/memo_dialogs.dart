import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/memo.dart';
import 'package:mneme_flutter/services/ai_summary.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:uuid/uuid.dart';

const Color _dlgBg = Color(0xFF0B1112);
const Color _dlgPanelBg = Color(0xFF10171A);
const Color _dlgFieldBg = Color(0xFF15171C);
const Color _dlgBorder = Color(0xFF223131);
const Color _dlgText = Color(0xFFEAF2F2);
const Color _dlgTextSub = Color(0xFF9FB3B3);
const Color _dlgAccent = Color(0xFF33A373);

class MemoCreateResult {
  final String categoryKey;
  /// 일정/상담 본문
  final String text;
  final String inquiryPhone;
  final String inquirySchoolGrade;
  final String inquiryAvailability;
  final String inquiryNote;

  const MemoCreateResult({
    required this.categoryKey,
    this.text = '',
    this.inquiryPhone = '',
    this.inquirySchoolGrade = '',
    this.inquiryAvailability = '',
    this.inquiryNote = '',
  });
}

class MemoInputDialog extends StatefulWidget {
  final String? initialCategoryKey; // schedule|consult|inquiry
  const MemoInputDialog({super.key, this.initialCategoryKey});

  @override
  State<MemoInputDialog> createState() => _MemoInputDialogState();
}

class _MemoInputDialogState extends State<MemoInputDialog> {
  final TextEditingController _controller = ImeAwareTextEditingController();
  final TextEditingController _inquiryPhone = ImeAwareTextEditingController();
  final TextEditingController _inquirySchoolGrade = ImeAwareTextEditingController();
  final TextEditingController _inquiryAvailability = ImeAwareTextEditingController();
  final TextEditingController _inquiryNote = ImeAwareTextEditingController();
  bool _saving = false;
  String _categoryKey = MemoCategory.schedule;

  @override
  void initState() {
    super.initState();
    final k = widget.initialCategoryKey;
    if (k == MemoCategory.schedule ||
        k == MemoCategory.consult ||
        k == MemoCategory.inquiry) {
      _categoryKey = k!;
    } else {
      _categoryKey = MemoCategory.schedule;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _inquiryPhone.dispose();
    _inquirySchoolGrade.dispose();
    _inquiryAvailability.dispose();
    _inquiryNote.dispose();
    super.dispose();
  }

  InputDecoration _decoration({String? hintText, String? labelText}) => InputDecoration(
        hintText: hintText,
        labelText: labelText,
        labelStyle: const TextStyle(color: _dlgTextSub),
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

  bool _inquiryHasAnyInput() {
    return _inquiryPhone.text.trim().isNotEmpty ||
        _inquirySchoolGrade.text.trim().isNotEmpty ||
        _inquiryAvailability.text.trim().isNotEmpty ||
        _inquiryNote.text.trim().isNotEmpty;
  }

  void _onSave() {
    if (_categoryKey == MemoCategory.inquiry) {
      if (!_inquiryHasAnyInput()) return;
    } else {
      if (_controller.text.trim().isEmpty) return;
    }
    setState(() => _saving = true);
    Navigator.of(context).pop(
      MemoCreateResult(
        categoryKey: _categoryKey,
        text: _controller.text,
        inquiryPhone: _inquiryPhone.text,
        inquirySchoolGrade: _inquirySchoolGrade.text,
        inquiryAvailability: _inquiryAvailability.text,
        inquiryNote: _inquiryNote.text,
      ),
    );
  }

  Widget _chip(String label, String key) {
    final selected = _categoryKey == key;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      selected: selected,
      onSelected: (_) => setState(() => _categoryKey = key),
      selectedColor: _dlgAccent,
      backgroundColor: _dlgPanelBg,
      labelStyle: TextStyle(color: selected ? Colors.white : _dlgTextSub),
      side: BorderSide(color: selected ? _dlgAccent : _dlgBorder, width: selected ? 2 : 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInquiry = _categoryKey == MemoCategory.inquiry;

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
                  _chip('일정', MemoCategory.schedule),
                  _chip('상담', MemoCategory.consult),
                  _chip('문의', MemoCategory.inquiry),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: SingleChildScrollView(
                child: isInquiry
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _inquiryPhone,
                            keyboardType: TextInputType.phone,
                            style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                            decoration: _decoration(labelText: '전화번호'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _inquirySchoolGrade,
                            style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                            decoration: _decoration(
                              labelText: '학교·학년',
                              hintText: '예: ○○중 2학년',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _inquiryAvailability,
                            minLines: 2,
                            maxLines: 4,
                            style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                            decoration: _decoration(
                              labelText: '가능한 요일 및 시간',
                              hintText: '자유 입력',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _inquiryNote,
                            minLines: 3,
                            maxLines: 8,
                            style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                            decoration: _decoration(labelText: '메모'),
                          ),
                        ],
                      )
                    : TextField(
                        controller: _controller,
                        minLines: 5,
                        maxLines: 10,
                        style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                        decoration: _decoration(hintText: '메모를 입력하세요'),
                      ),
              ),
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
          onPressed: _saving ? null : _onSave,
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

class MemoInquiryEditResult {
  final MemoEditAction action;
  final String phone;
  final String schoolGrade;
  final String availability;
  final String note;
  const MemoInquiryEditResult({
    required this.action,
    this.phone = '',
    this.schoolGrade = '',
    this.availability = '',
    this.note = '',
  });
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

class MemoInquiryEditDialog extends StatefulWidget {
  final String initialPhone;
  final String initialSchoolGrade;
  final String initialAvailability;
  final String initialNote;
  final String fallbackOriginal;

  const MemoInquiryEditDialog({
    super.key,
    this.initialPhone = '',
    this.initialSchoolGrade = '',
    this.initialAvailability = '',
    this.initialNote = '',
    this.fallbackOriginal = '',
  });

  @override
  State<MemoInquiryEditDialog> createState() => _MemoInquiryEditDialogState();
}

class _MemoInquiryEditDialogState extends State<MemoInquiryEditDialog> {
  late final TextEditingController _phone;
  late final TextEditingController _schoolGrade;
  late final TextEditingController _availability;
  late final TextEditingController _note;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _phone = ImeAwareTextEditingController(text: widget.initialPhone);
    _schoolGrade = ImeAwareTextEditingController(text: widget.initialSchoolGrade);
    _availability = ImeAwareTextEditingController(text: widget.initialAvailability);
    _note = ImeAwareTextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _phone.dispose();
    _schoolGrade.dispose();
    _availability.dispose();
    _note.dispose();
    super.dispose();
  }

  InputDecoration _decoration({String? hintText, String? labelText}) => InputDecoration(
        hintText: hintText,
        labelText: labelText,
        labelStyle: const TextStyle(color: _dlgTextSub),
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

  bool _hasAny() {
    return _phone.text.trim().isNotEmpty ||
        _schoolGrade.text.trim().isNotEmpty ||
        _availability.text.trim().isNotEmpty ||
        _note.text.trim().isNotEmpty;
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
        '문의 수정',
        style: TextStyle(color: _dlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Divider(color: _dlgBorder, height: 1),
              const SizedBox(height: 16),
              if (widget.initialPhone.isEmpty &&
                  widget.initialSchoolGrade.isEmpty &&
                  widget.initialAvailability.isEmpty &&
                  widget.initialNote.isEmpty &&
                  widget.fallbackOriginal.trim().isNotEmpty) ...[
                Text(
                  '이전 형식 메모입니다. 아래에서 수정하거나 통합 본문을 참고하세요.',
                  style: TextStyle(color: _dlgTextSub.withOpacity(0.95), fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _dlgPanelBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _dlgBorder),
                  ),
                  child: Text(
                    widget.fallbackOriginal,
                    style: const TextStyle(color: _dlgTextSub, fontSize: 13, height: 1.35),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                decoration: _decoration(labelText: '전화번호'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _schoolGrade,
                style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                decoration: _decoration(labelText: '학교·학년', hintText: '예: ○○중 2학년'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _availability,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                decoration: _decoration(labelText: '가능한 요일 및 시간', hintText: '자유 입력'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                minLines: 3,
                maxLines: 8,
                style: const TextStyle(color: _dlgText, fontSize: 14, height: 1.35),
                decoration: _decoration(labelText: '메모'),
              ),
            ],
          ),
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
              : () => Navigator.of(context).pop(
                    MemoInquiryEditResult(action: MemoEditAction.delete),
                  ),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFB74C4C),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('삭제', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
        FilledButton(
          onPressed: _saving || !_hasAny()
              ? null
              : () {
                  setState(() => _saving = true);
                  Navigator.of(context).pop(
                    MemoInquiryEditResult(
                      action: MemoEditAction.save,
                      phone: _phone.text,
                      schoolGrade: _schoolGrade.text,
                      availability: _availability.text,
                      note: _note.text,
                    ),
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

/// 일정/상담: AI 일정 추출·요약. 문의: 구조 필드만 저장.
Future<void> addMemoFromCreateResult(MemoCreateResult result) async {
  final cat = MemoCategory.normalize(result.categoryKey);
  if (cat == MemoCategory.inquiry) {
    final any = result.inquiryPhone.trim().isNotEmpty ||
        result.inquirySchoolGrade.trim().isNotEmpty ||
        result.inquiryAvailability.trim().isNotEmpty ||
        result.inquiryNote.trim().isNotEmpty;
    if (!any) return;
    final now = DateTime.now();
    final sort = DataManager.instance.nextInquirySortIndexForAppend();
    final memo = memoNewInquiry(
      id: const Uuid().v4(),
      now: now,
      phone: result.inquiryPhone,
      schoolGrade: result.inquirySchoolGrade,
      availability: result.inquiryAvailability,
      note: result.inquiryNote,
      sortIndex: sort,
    );
    await DataManager.instance.addMemo(memo);
    return;
  }
  final text = result.text.trim();
  if (text.isEmpty) return;
  final now = DateTime.now();
  final scheduledAt = await AiSummaryService.extractDateTime(text);
  final memo = memoNewPlain(
    id: const Uuid().v4(),
    now: now,
    original: text,
    categoryKey: cat,
    scheduledAt: scheduledAt,
  );
  await DataManager.instance.addMemo(memo);
  try {
    final summary = await AiSummaryService.summarize(memo.original);
    await DataManager.instance.updateMemo(
      memo.copyWith(summary: summary, updatedAt: DateTime.now()),
    );
  } catch (_) {}
}

Future<void> applyMemoInquiryEdit({
  required Memo item,
  required MemoInquiryEditResult edited,
}) async {
  if (edited.action == MemoEditAction.delete) {
    await DataManager.instance.deleteMemo(item.id);
    return;
  }
  final p = edited.phone.trim();
  final s = edited.schoolGrade.trim();
  final a = edited.availability.trim();
  final n = edited.note.trim();
  if (p.isEmpty && s.isEmpty && a.isEmpty && n.isEmpty) return;
  final updated = item.copyWith(
    original: memoInquiryOriginalJoined(
      phone: p,
      schoolGrade: s,
      availability: a,
      note: n,
    ),
    summary: memoInquirySummaryLine(
      phone: p,
      schoolGrade: s,
      availability: a,
      note: n,
    ),
    inquiryPhone: p.isEmpty ? null : p,
    inquirySchoolGrade: s.isEmpty ? null : s,
    inquiryAvailability: a.isEmpty ? null : a,
    inquiryNote: n.isEmpty ? null : n,
    updatedAt: DateTime.now(),
  );
  await DataManager.instance.updateMemo(updated);
}
