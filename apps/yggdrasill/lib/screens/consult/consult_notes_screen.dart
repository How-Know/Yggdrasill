import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:uuid/uuid.dart';

import '../../models/consult_note.dart';
import '../../models/operating_hours.dart';
import '../../services/consult_note_controller.dart';
import '../../services/consult_note_service.dart';
import '../../services/consult_inquiry_demand_service.dart';
import '../../services/consult_trial_lesson_service.dart';
import '../../services/data_manager.dart';
import '../timetable/components/timetable_header.dart';
import '../timetable/views/classes_view.dart';

const Color _bg = Color(0xFF0B1112);
const Color _panelBg = Color(0xFF10171A);
const Color _border = Color(0xFF223131);
const Color _text = Color(0xFFEAF2F2);
const Color _accent = Color(0xFF33A373);
// 템플릿(배경 가이드) 텍스트는 사용자 필기보다 "눈에 보이되" 방해되지 않도록 회색 톤으로.
const Color _templateInk = Color(0xFF9FB3B3);

class ConsultNotesScreen extends StatefulWidget {
  const ConsultNotesScreen({super.key});

  @override
  State<ConsultNotesScreen> createState() => _ConsultNotesScreenState();
}

class _ConsultNotesScreenState extends State<ConsultNotesScreen> {
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  ConsultNote? _note;
  List<HandwritingStroke> _strokes = <HandwritingStroke>[];
  HandwritingStroke? _inProgress;

  // 시범 수업(일회성) 일정 선택 상태 (노트 저장 시점에 로컬 시간표에 반영)
  DateTime? _trialWeekStart; // 월요일(date-only)
  Set<String> _trialSlotKeys = <String>{}; // '$dayIdx-$hour:$minute'

  Future<void> _saveAndExitFlow() async {
    final ok = await _saveWithTitlePrompt();
    if (!ok || !mounted) return;
    // 진입 전 페이지로 복귀
    unawaited(Navigator.of(context, rootNavigator: true).maybePop());
  }

  // 펜 설정
  Color _penColor = Colors.white;
  double _penWidth = 3.6;
  double _eraserWidth = 40.0;
  bool _eraser = false;

  int? _activePointer;

  @override
  void initState() {
    super.initState();
    ConsultNoteController.instance.isScreenOpen = true;
    ConsultNoteController.instance.requestedNoteId.addListener(_onRequestedNoteChanged);
    unawaited(_boot());
  }

  @override
  void dispose() {
    ConsultNoteController.instance.requestedNoteId.removeListener(_onRequestedNoteChanged);
    ConsultNoteController.instance.isScreenOpen = false;
    super.dispose();
  }

  void _onRequestedNoteChanged() {
    final id = ConsultNoteController.instance.consumeRequested();
    if (id == null || id.isEmpty) return;
    unawaited(_openNoteById(id));
  }

  Future<void> _openNoteById(String id) async {
    if (!mounted) return;
    final ok = await _confirmHandleDirtyIfNeeded();
    if (!ok) return;
    final note = await ConsultNoteService.instance.load(id);
    if (note == null || !mounted) return;
    setState(() {
      _note = note;
      _strokes = [...note.strokes];
      _inProgress = null;
      _dirty = false;
    });
    unawaited(_loadTrialSelectionForNote(note.id));
  }

  Future<void> _boot() async {
    setState(() => _loading = true);
    final metas = await ConsultNoteService.instance.listMetas();
    ConsultNote? note;
    // 외부(오른쪽 슬라이드)에서 특정 노트 오픈 요청이 있으면 우선 적용
    final requested = ConsultNoteController.instance.consumeRequested();
    if (requested != null && requested.isNotEmpty) {
      note = await ConsultNoteService.instance.load(requested);
    }
    if (note == null && metas.isNotEmpty) {
      note = await ConsultNoteService.instance.load(metas.first.id);
    }
    final ConsultNote bootNote = note ?? _newBlankNote();
    setState(() {
      _note = bootNote;
      _strokes = [...bootNote.strokes];
      _inProgress = null;
      _dirty = false;
      _loading = false;
    });
    unawaited(_loadTrialSelectionForNote(bootNote.id));
  }

  ConsultNote _newBlankNote({String? title}) {
    final now = DateTime.now();
    return ConsultNote(
      id: const Uuid().v4(),
      title: (title == null || title.trim().isEmpty) ? '문의 노트' : title.trim(),
      createdAt: now,
      updatedAt: now,
      strokes: const <HandwritingStroke>[],
    );
  }

  Future<void> _loadTrialSelectionForNote(String noteId) async {
    try {
      await ConsultTrialLessonService.instance.load();
    } catch (_) {}
    if (!mounted) return;
    if (_note?.id != noteId) return;
    final slots = ConsultTrialLessonService.instance.slots.where((s) => s.sourceNoteId == noteId).toList();
    setState(() {
      if (slots.isEmpty) {
        _trialWeekStart = null;
        _trialSlotKeys = <String>{};
      } else {
        final wk = slots.first.weekStart;
        _trialWeekStart = DateTime(wk.year, wk.month, wk.day);
        _trialSlotKeys = slots.map((s) => ConsultTrialLessonService.slotKey(s.dayIndex, s.hour, s.minute)).toSet();
      }
    });
  }

  Future<bool> _confirmHandleDirtyIfNeeded() async {
    if (!_dirty) return true;
    final action = await showDialog<_DirtyAction>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _border),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          title: const Text(
            '저장하지 않은 변경사항',
            style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w900),
          ),
          content: const Text(
            '현재 노트에 저장하지 않은 내용이 있습니다.\n저장할까요?',
            style: TextStyle(color: Colors.white70, height: 1.4, fontWeight: FontWeight.w700),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_DirtyAction.cancel),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF9FB3B3),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_DirtyAction.discard),
              style: TextButton.styleFrom(
                foregroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
              child: const Text('버리기'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _accent, // 0xFF33A373
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(_DirtyAction.save),
              child: const Text(
                '저장',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (action == _DirtyAction.save) {
      return await _saveWithTitlePrompt();
    }
    return action == _DirtyAction.discard;
  }

  Future<void> _save() async {
    final n = _note;
    if (n == null) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final updated = n.copyWith(
        updatedAt: now,
        strokes: List<HandwritingStroke>.unmodifiable(_strokes),
      );
      await ConsultNoteService.instance.save(updated);
      // 희망 수업시간(다중선택) → 시간표 오버레이/정원 카운트에 반영(노트 저장 시점)
      final slotKeys = updated.desiredSlots.map((s) => s.slotKey).toSet();
      var startWeek = updated.desiredStartWeek;
      if (slotKeys.isNotEmpty && startWeek == null) {
        // 레거시/예외 케이스 대비: 시작 주가 비어있으면 "이번 주"로 간주
        final now2 = DateTime.now();
        startWeek = DateTime(now2.year, now2.month, now2.day).subtract(Duration(days: now2.weekday - 1));
      }
      if (slotKeys.isNotEmpty && startWeek != null) {
        await ConsultInquiryDemandService.instance.upsertForNote(
          noteId: updated.id,
          title: updated.title,
          startWeek: startWeek,
          slotKeys: slotKeys,
        );
      } else {
        // 선택이 없다면 기존 반영분이 있을 수 있으므로 정리
        await ConsultInquiryDemandService.instance.removeForNote(updated.id);
      }

      // 시범 수업(일회성) 일정 → 선택한 주차(weekStart)에서만 시간표에 반영
      final trialKeys = _trialSlotKeys;
      var trialWeek = _trialWeekStart;
      if (trialKeys.isNotEmpty && trialWeek == null) {
        final now2 = DateTime.now();
        trialWeek = DateTime(now2.year, now2.month, now2.day).subtract(Duration(days: now2.weekday - 1));
      }
      if (trialKeys.isNotEmpty && trialWeek != null) {
        await ConsultTrialLessonService.instance.upsertForNote(
          noteId: updated.id,
          title: updated.title,
          weekStart: trialWeek,
          slotKeys: trialKeys,
        );
      } else {
        await ConsultTrialLessonService.instance.removeForNote(updated.id);
      }

      if (!mounted) return;
      setState(() {
        _note = updated;
        _dirty = false;
      });
      if (mounted) {
        final bool hasDesired = slotKeys.isNotEmpty && startWeek != null;
        final bool hasTrial = trialKeys.isNotEmpty && trialWeek != null;
        if (hasDesired && hasTrial) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장되었습니다. (희망/시범 일정이 시간표에 반영됨)')));
        } else if (hasDesired) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장되었습니다. (희망 수업 일정이 시간표에 반영됨)')));
        } else if (hasTrial) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장되었습니다. (시범 수업 일정이 시간표에 반영됨)')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장되었습니다.')));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장에 실패했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveWithTitlePrompt() async {
    if (_saving) return false;
    final n = _note;
    if (n == null) return false;

    final ctrl = TextEditingController(text: n.title);
    String? result;
    result = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setSB) {
          final canSave = ctrl.text.trim().isNotEmpty;
          return AlertDialog(
            backgroundColor: _bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: _border),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
            contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            title: const Text(
              '제목 입력',
              style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              // 기존(520) 대비 약 -30%
              width: 360,
              child: TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setSB(() {}),
                style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  labelText: '제목',
                  labelStyle: const TextStyle(color: Color(0xFF9FB3B3)),
                  hintText: '예: 등록 문의 - 김OO',
                  hintStyle: const TextStyle(color: Colors.white38),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: const Color(0xFF3A3F44).withValues(alpha: 153)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _accent, width: 1.4),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF15171C),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx2).pop(null),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF9FB3B3),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                ),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent, // 0xFF33A373
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: canSave ? () => Navigator.of(ctx2).pop(ctrl.text) : null,
                child: const Text(
                  '저장',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        });
      },
    );
    ctrl.dispose();

    if (result == null) return false;
    final title = result.trim();
    if (title.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('제목을 입력하세요.')));
      }
      return false;
    }

    setState(() {
      _note = _note!.copyWith(title: title);
      _dirty = true;
    });
    await _save();
    return true;
  }

  Future<void> _newNoteFlow() async {
    final ok = await _confirmHandleDirtyIfNeeded();
    if (!ok) return;
    final created = _newBlankNote();
    setState(() {
      _note = created;
      _strokes = <HandwritingStroke>[];
      _inProgress = null;
      _trialWeekStart = null;
      _trialSlotKeys = <String>{};
      _dirty = false;
    });
  }

  Future<void> _renameFlow() async {
    final n = _note;
    if (n == null) return;
    final ctrl = TextEditingController(text: n.title);
    final nextTitle = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('노트 이름 변경', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '이름',
              hintStyle: TextStyle(color: Colors.white38),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (nextTitle == null || nextTitle.trim().isEmpty) return;
    final updated = n.copyWith(title: nextTitle.trim(), updatedAt: DateTime.now());
    setState(() {
      _note = updated;
      _dirty = true;
    });
    await _save();
  }

  Future<void> _deleteFlow() async {
    final n = _note;
    if (n == null) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('노트 삭제', style: TextStyle(color: Colors.white)),
          content: Text('정말 삭제할까요?\n\n"${n.title}"', style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    await ConsultNoteService.instance.delete(n.id);
    await ConsultInquiryDemandService.instance.removeForNote(n.id);
    await ConsultTrialLessonService.instance.removeForNote(n.id);
    final metas = await ConsultNoteService.instance.listMetas();
    ConsultNote? next;
    if (metas.isNotEmpty) {
      next = await ConsultNoteService.instance.load(metas.first.id);
    }
    final ConsultNote nextNote = next ?? _newBlankNote();
    if (!mounted) return;
    setState(() {
      _note = nextNote;
      _strokes = [...nextNote.strokes];
      _inProgress = null;
      _dirty = false;
    });
    unawaited(_loadTrialSelectionForNote(nextNote.id));
  }

  // 노트 선택(열기) UI는 상단 버튼에서 제거됨.
  // 오른쪽 슬라이드(메모 패널)에서 '문의' 탭을 통해 상담 노트 목록을 공유/선택하도록 이동.

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes = [..._strokes]..removeLast();
      _dirty = true;
    });
  }

  void _clearAll() {
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes = <HandwritingStroke>[];
      _inProgress = null;
      _dirty = true;
    });
  }

  Future<void> _onCheckSchedulePressed() async {
    final n = _note;
    if (n == null) return;
    if (!mounted) return;
    final picked = await showDialog<_InquirySchedulePickResult>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ConsultTimetablePickerDialog(
        titleText: '희망 수업시간 선택',
        initialWeekStart: n.desiredStartWeek,
        initialSlotKeys: n.desiredSlots.map((s) => s.slotKey).toSet(),
      ),
    );
    if (picked == null || !mounted) return;

    // 문의 노트 저장 시점에(상단 저장 버튼) 희망시간이 시간표에 반영되도록
    // 여기서는 선택값만 노트에 저장해 둔다.
    final List<ConsultDesiredSlot> slots = <ConsultDesiredSlot>[];
    for (final key in picked.slotKeys) {
      final parts = key.split('-');
      if (parts.length != 2) continue;
      final dayIdx = int.tryParse(parts[0]);
      final hm = parts[1].split(':');
      if (dayIdx == null || hm.length != 2) continue;
      final hh = int.tryParse(hm[0]);
      final mm = int.tryParse(hm[1]);
      if (hh == null || mm == null) continue;
      slots.add(ConsultDesiredSlot(dayIndex: dayIdx, hour: hh, minute: mm));
    }
    slots.sort((a, b) {
      final da = a.dayIndex.compareTo(b.dayIndex);
      if (da != 0) return da;
      final ha = a.hour.compareTo(b.hour);
      if (ha != 0) return ha;
      return a.minute.compareTo(b.minute);
    });

    // 레거시 단일값도 함께 업데이트(선택이 있으면 첫 슬롯을 대표값으로 기록)
    int? legacyW;
    int? legacyH;
    int? legacyM;
    if (slots.isNotEmpty) {
      legacyW = slots.first.dayIndex + 1; // 1..7
      legacyH = slots.first.hour;
      legacyM = slots.first.minute;
    }

    setState(() {
      _note = n.copyWith(
        desiredStartWeek: DateTime(picked.weekStart.year, picked.weekStart.month, picked.weekStart.day),
        desiredSlots: List<ConsultDesiredSlot>.unmodifiable(slots),
        desiredWeekday: legacyW,
        desiredHour: legacyH,
        desiredMinute: legacyM,
      );
      _dirty = true;
    });
  }

  void _onTrialLessonPressed() {
    unawaited(_onTrialSchedulePressed());
  }

  Future<void> _onTrialSchedulePressed() async {
    final n = _note;
    if (n == null) return;
    if (!mounted) return;
    final picked = await showDialog<_InquirySchedulePickResult>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ConsultTimetablePickerDialog(
        titleText: '시범 수업시간 선택',
        initialWeekStart: _trialWeekStart,
        initialSlotKeys: _trialSlotKeys,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _trialWeekStart = DateTime(picked.weekStart.year, picked.weekStart.month, picked.weekStart.day);
      _trialSlotKeys = <String>{...picked.slotKeys};
      _dirty = true;
    });
  }

  void _setEraser(bool value) {
    setState(() {
      _eraser = value;
      if (value) {
        // 요구사항: 지우개 선택 시 기본 두께는 40
        _eraserWidth = 40.0;
      }
    });
  }

  Future<void> _pickPenColor() async {
    Color temp = _penColor;
    final picked = await showDialog<Color>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('펜 색상', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: BlockPicker(
              pickerColor: _penColor,
              onColorChanged: (c) => temp = c,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () => Navigator.of(ctx).pop(temp),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _eraser = false;
      _penColor = picked;
    });
  }

  Future<void> _pickPenWidth() async {
    final isEraser = _eraser;
    double temp = isEraser ? _eraserWidth : _penWidth;
    final double min = isEraser ? 10.0 : 1.0;
    final double max = isEraser ? 80.0 : 18.0;
    final int divisions = isEraser ? 70 : 17;
    final picked = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: Text(isEraser ? '지우개 두께' : '펜 두께', style: const TextStyle(color: Colors.white)),
          content: StatefulBuilder(builder: (ctx2, setSB) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: temp.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  activeColor: isEraser ? const Color(0xFFB74C4C) : _accent,
                  label: isEraser ? temp.toStringAsFixed(0) : temp.toStringAsFixed(1),
                  onChanged: (v) => setSB(() => temp = v),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 260,
                  height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Center(
                    child: Container(
                      width: 180,
                      height: 1,
                      color: Colors.transparent,
                      child: CustomPaint(
                        painter: _LinePreviewPainter(color: isEraser ? Colors.white70 : _penColor, width: temp),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () => Navigator.of(ctx).pop(temp),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    if (picked == null) return;
    setState(() {
      if (isEraser) {
        _eraserWidth = picked;
      } else {
        _penWidth = picked;
      }
    });
  }

  bool _canDraw(PointerDeviceKind kind) {
    // 요구사항: 터치/펜 기반. 마우스도 디버그용으로 허용.
    return kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.touch || kind == PointerDeviceKind.mouse;
  }

  void _startStroke(PointerDownEvent e, Size size) {
    if (!_canDraw(e.kind)) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton) return;
    if (_activePointer != null) return;
    _activePointer = e.pointer;
    final color = _eraser ? Colors.transparent : _penColor;
    final p = _toNormalized(e.localPosition, size, e.pressure);
    setState(() {
      _inProgress = HandwritingStroke(
        colorArgb: color.toARGB32(),
        width: _eraser ? _eraserWidth : _penWidth,
        isEraser: _eraser,
        points: <HandwritingPoint>[p],
      );
      _dirty = true;
    });
  }

  void _appendStroke(PointerMoveEvent e, Size size) {
    if (_activePointer != e.pointer) return;
    final s = _inProgress;
    if (s == null) return;
    final newLocal = e.localPosition;
    final List<HandwritingPoint> extra = <HandwritingPoint>[];
    if (s.points.isNotEmpty) {
      final last = s.points.last;
      final lastLocal = Offset(last.nx * size.width, last.ny * size.height);
      final dist = (newLocal - lastLocal).distance;
      // 포인트 간격이 크면 중간점을 보간해서 곡선 계단 현상 완화
      const double step = 2.0; // px
      if (dist > step) {
        final count = (dist / step).floor();
        for (int i = 1; i <= count; i++) {
          final t = i / (count + 1);
          final interp = Offset(
            lastLocal.dx + (newLocal.dx - lastLocal.dx) * t,
            lastLocal.dy + (newLocal.dy - lastLocal.dy) * t,
          );
          extra.add(_toNormalized(interp, size, e.pressure));
        }
      }
    }
    final p = _toNormalized(newLocal, size, e.pressure);
    setState(() {
      _inProgress = s.copyWith(points: [...s.points, ...extra, p]);
    });
  }

  void _endStroke(PointerUpEvent e) {
    if (_activePointer != e.pointer) return;
    final s = _inProgress;
    setState(() {
      _activePointer = null;
      _inProgress = null;
      if (s != null && s.points.isNotEmpty) {
        _strokes = [..._strokes, s];
      }
    });
  }

  void _cancelStroke(PointerCancelEvent e) {
    if (_activePointer != e.pointer) return;
    setState(() {
      _activePointer = null;
      _inProgress = null;
    });
  }

  HandwritingPoint _toNormalized(Offset local, Size size, double pressure) {
    final w = size.width <= 1 ? 1.0 : size.width;
    final h = size.height <= 1 ? 1.0 : size.height;
    double nx = local.dx / w;
    double ny = local.dy / h;
    if (nx.isNaN || nx.isInfinite) nx = 0;
    if (ny.isNaN || ny.isInfinite) ny = 0;
    nx = nx.clamp(0.0, 1.0);
    ny = ny.clamp(0.0, 1.0);
    final p = (pressure.isNaN || pressure.isInfinite) ? null : pressure.clamp(0.0, 1.0);
    return HandwritingPoint(nx: nx, ny: ny, pressure: p);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDesiredSelection = (_note?.desiredSlots.isNotEmpty ?? false);
    final bool hasTrialSelection = _trialSlotKeys.isNotEmpty;
    return WillPopScope(
      onWillPop: () async {
        final ok = await _confirmHandleDirtyIfNeeded();
        return ok;
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: _text,
          elevation: 0,
          titleSpacing: 0,
          title: SizedBox(
            width: double.infinity,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('문의 노트', style: TextStyle(fontWeight: FontWeight.w900)),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: '새 노트',
                        onPressed: _loading ? null : () => unawaited(_newNoteFlow()),
                        icon: const Icon(Icons.note_add_outlined),
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        padding: EdgeInsets.zero,
                      ),
                      PopupMenuButton<_MoreAction>(
                        tooltip: '더보기',
                        color: const Color(0xFF1F1F1F),
                        onSelected: (v) {
                          switch (v) {
                            case _MoreAction.rename:
                              unawaited(_renameFlow());
                              break;
                            case _MoreAction.delete:
                              unawaited(_deleteFlow());
                              break;
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: _MoreAction.rename,
                            child: Text('이름 변경', style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: _MoreAction.delete,
                            child: Text('삭제', style: TextStyle(color: Colors.redAccent)),
                          ),
                        ],
                        child: const SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(child: Icon(Icons.more_horiz, color: Colors.white70)),
                        ),
                      ),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TopOutlineActionButton(
                        label: '희망 수업 일정',
                        icon: hasDesiredSelection ? Icons.check_rounded : Icons.event_note_outlined,
                        onPressed: _loading ? null : _onCheckSchedulePressed,
                      ),
                      const SizedBox(width: 10),
                      _TopOutlineActionButton(
                        label: '시범 수업 일정',
                        icon: hasTrialSelection ? Icons.check_rounded : Icons.play_lesson_outlined,
                        onPressed: _loading ? null : _onTrialLessonPressed,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: '되돌리기',
              onPressed: _strokes.isNotEmpty ? _undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: '전체삭제',
              onPressed: _strokes.isNotEmpty ? _clearAll : null,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 2),
              child: SizedBox(
                height: 36,
                child: FilledButton(
                  onPressed: (_saving || _note == null) ? null : () => unawaited(_saveAndExitFlow()),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(horizontal: 27), // +50%
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('저장', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: _loading
            ? null
            : _BottomDrawFabBar(
                eraser: _eraser,
                penColor: _penColor,
                penWidth: _penWidth,
                eraserWidth: _eraserWidth,
                onSelectPen: () => _setEraser(false),
                onSelectEraser: () => _setEraser(true),
                onPickColor: () => unawaited(_pickPenColor()),
                onPickWidth: () => unawaited(_pickPenWidth()),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _panelBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _border),
                        ),
                        child: LayoutBuilder(builder: (ctx, constraints) {
                          final size = Size(constraints.maxWidth, constraints.maxHeight);
                          return Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (e) => _startStroke(e, size),
                            onPointerMove: (e) => _appendStroke(e, size),
                            onPointerUp: _endStroke,
                            onPointerCancel: _cancelStroke,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: _HandwritingPainter(
                                  strokes: _strokes,
                                  inProgress: _inProgress,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

enum _DirtyAction { save, discard, cancel }
enum _MoreAction { rename, delete }

class _TopOutlineActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _TopOutlineActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      height: 44,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF1B6B63),
          side: const BorderSide(color: Color(0xFF1B6B63), width: 1.6),
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }
}

class _BottomDrawFabBar extends StatelessWidget {
  final bool eraser;
  final Color penColor;
  final double penWidth;
  final double eraserWidth;
  final VoidCallback onSelectPen;
  final VoidCallback onSelectEraser;
  final VoidCallback onPickColor;
  final VoidCallback onPickWidth;

  const _BottomDrawFabBar({
    required this.eraser,
    required this.penColor,
    required this.penWidth,
    required this.eraserWidth,
    required this.onSelectPen,
    required this.onSelectEraser,
    required this.onPickColor,
    required this.onPickWidth,
  });

  double _previewWidth(double w) {
    // 표시용은 너무 두꺼우면 버튼을 꽉 채워보이므로 상한을 둔다.
    return w.clamp(2.0, 8.0);
  }

  @override
  Widget build(BuildContext context) {
    final currentWidth = eraser ? eraserWidth : penWidth;
    final previewW = _previewWidth(currentWidth);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              height: 56,
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xCC10171A),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0x22223131)),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 16, offset: Offset(0, 6)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BottomToolToggle(
                    selected: !eraser,
                    label: '펜',
                    width: 78,
                    bg: _accent,
                    icon: Icons.edit_rounded,
                    onTap: onSelectPen,
                  ),
                  const SizedBox(width: 8),
                  _BottomToolToggle(
                    selected: eraser,
                    label: '지우개',
                    width: 92,
                    bg: const Color(0xFFB74C4C),
                    icon: Icons.cleaning_services_rounded,
                    onTap: onSelectEraser,
                  ),
                  const SizedBox(width: 10),
                  // 색상: 아이콘 없이 현재 색상 인디케이터만
                  _BottomToolIcon(
                    tooltip: '색상',
                    onTap: onPickColor,
                    padding: const EdgeInsets.fromLTRB(6, 6, 3, 6), // 오른쪽 여백 축소
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: penColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 1.2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5), // 색상-두께 간격 절반
                  // 두께: 고정 폭으로 유지(펜/지우개 전환 시 전체 폭이 변하지 않게)
                  _BottomToolIcon(
                    tooltip: eraser ? '지우개 두께' : '펜 두께',
                    onTap: onPickWidth,
                    padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
                    child: SizedBox(
                      width: 58,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 42,
                          height: 22,
                          child: CustomPaint(
                            painter: _LinePreviewPainter(
                              color: eraser ? Colors.white70 : penColor,
                              width: previewW,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomToolIcon extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsets padding;

  const _BottomToolIcon({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.padding = const EdgeInsets.all(6),
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.white.withValues(alpha: 16),
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 200),
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _BottomToolToggle extends StatelessWidget {
  final bool selected;
  final String label;
  final double width;
  final Color bg;
  final IconData icon;
  final VoidCallback onTap;

  const _BottomToolToggle({
    required this.selected,
    required this.label,
    required this.width,
    required this.bg,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : Colors.white70;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.white.withValues(alpha: 16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: width,
          height: 40,
          decoration: BoxDecoration(
            color: selected ? bg : Colors.white10,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InquirySchedulePickResult {
  final DateTime weekStart; // 월요일(해당 주 시작)
  final Set<String> slotKeys; // '$dayIdx-$hour:$minute'
  const _InquirySchedulePickResult({required this.weekStart, required this.slotKeys});
}

class _ConsultTimetablePickerDialog extends StatefulWidget {
  final DateTime? initialWeekStart; // 월요일(date-only)
  final Set<String>? initialSlotKeys; // '$dayIdx-$hour:$minute'
  final String titleText;

  const _ConsultTimetablePickerDialog({
    this.titleText = '희망 수업시간 선택',
    this.initialWeekStart,
    this.initialSlotKeys,
  });

  @override
  State<_ConsultTimetablePickerDialog> createState() => _ConsultTimetablePickerDialogState();
}

class _ConsultTimetablePickerDialogState extends State<_ConsultTimetablePickerDialog> {
  bool _loading = true;
  List<OperatingHours> _hours = <OperatingHours>[];
  late DateTime _weekStart; // 월요일(해당 주 시작)
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final init = widget.initialWeekStart;
    _weekStart = (init == null)
        ? DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1))
        : DateTime(init.year, init.month, init.day);
    final initKeys = widget.initialSlotKeys;
    if (initKeys != null && initKeys.isNotEmpty) {
      _selected.addAll(initKeys);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hours = await DataManager.instance.getOperatingHours();
      if (!mounted) return;
      setState(() {
        _hours = hours;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hours = <OperatingHours>[];
        _loading = false;
      });
    }
  }

  void _toggleFromGrid(int dayIdx, DateTime startTime) {
    final k = ConsultInquiryDemandService.slotKey(dayIdx, startTime.hour, startTime.minute);
    setState(() {
      if (_selected.contains(k)) {
        _selected.remove(k);
      } else {
        _selected.add(k);
      }
    });
  }

  String _selectedLabel() {
    if (_selected.isEmpty) return '선택 없음';
    String dayKo(int dayIdx) {
      const days = ['월', '화', '수', '목', '금', '토', '일'];
      return (dayIdx >= 0 && dayIdx < days.length) ? days[dayIdx] : '$dayIdx';
    }

    String two(int n) => n.toString().padLeft(2, '0');
    final items = _selected
        .map((k) {
          final parts = k.split('-');
          if (parts.length != 2) return null;
          final dayIdx = int.tryParse(parts[0]);
          final hm = parts[1].split(':');
          if (dayIdx == null || hm.length != 2) return null;
          final hh = int.tryParse(hm[0]);
          final mm = int.tryParse(hm[1]);
          if (hh == null || mm == null) return null;
          return '${dayKo(dayIdx)} ${two(hh)}:${two(mm)}';
        })
        .whereType<String>()
        .toList();
    items.sort();
    return items.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selected.isNotEmpty;
    return AlertDialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.titleText,
            style: const TextStyle(color: _text, fontSize: 20, fontWeight: FontWeight.w800),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            '선택: ${_selectedLabel()}',
            style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w700, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: 1032,
        height: 874, // +30%
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _accent))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 시간탭과 동일한 헤더 사용
                  TimetableHeader(
                    selectedDate: _weekStart,
                    onDateChanged: (newDate) {
                      final monday = newDate.subtract(Duration(days: newDate.weekday - 1));
                      setState(() {
                        _weekStart = DateTime(monday.year, monday.month, monday.day);
                      });
                    },
                    selectedDayIndex: null,
                    onDaySelected: (_) {},
                    isRegistrationMode: false,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _hours.isEmpty
                        ? const Center(
                            child: Text(
                              '운영시간 정보를 불러오지 못했습니다.',
                              style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w700),
                            ),
                          )
                        : ClassesView(
                            scrollController: _scrollController,
                            operatingHours: _hours,
                            breakTimeColor: const Color(0xFF424242),
                            registrationModeType: null,
                            isRegistrationMode: false,
                            selectedDayIndex: null,
                            selectedCellDayIndex: null,
                            selectedCellStartTime: null,
                            selectedSlotKeys: _selected,
                            weekStartDate: _weekStart,
                            selectedStudentWithInfo: null,
                            onTimeSelected: (dayIdx, startTime) => _toggleFromGrid(dayIdx, startTime),
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          style: TextButton.styleFrom(
            foregroundColor: _templateInk,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: hasSelection
              ? () => Navigator.of(context).pop<_InquirySchedulePickResult>(
                    _InquirySchedulePickResult(
                      weekStart: _weekStart,
                      slotKeys: Set<String>.unmodifiable(_selected),
                    ),
                  )
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('선택', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}

class _HandwritingPainter extends CustomPainter {
  final List<HandwritingStroke> strokes;
  final HandwritingStroke? inProgress;

  _HandwritingPainter({required this.strokes, required this.inProgress});

  @override
  void paint(Canvas canvas, Size size) {
    _paintTemplate(canvas, size);

    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    for (final s in strokes) {
      _paintStroke(canvas, size, s);
    }
    if (inProgress != null) {
      _paintStroke(canvas, size, inProgress!);
    }
    canvas.restore();
  }

  void _paintTemplate(Canvas canvas, Size size) {
    const pad = 18.0;
    const leftPad = pad * 2;
    // 요청사항:
    // - 템플릿의 "줄"은 모두 제거(구분선/밑줄/줄노트/박스 테두리 등).
    // - 1행: 연락처, 학교, 학년
    // - 2행: 진도
    // - 3행: 상담 내용
    // - 템플릿 글자는 3배 크게(기존 12~13px -> 36~39px 수준) + 더 잘 보이는 회색

    const double labelFont = 36.0; // 12 * 3
    const double labelGapX = 18.0;
    // 세로 배치 비율: 1 : 1 : 2 (총 4등분)
    // 템플릿 상단 여백(조금 더 내려서 시작)
    const top = pad + 12.0;
    final bottom = size.height - pad;
    final totalH = (bottom - top).clamp(1.0, 999999.0);
    final unit = totalH / 4.0;
    const y1 = top;
    final y2 = top + unit * 1.0;
    final y3 = top + unit * 2.0;

    final w = size.width;
    final avail = (w - leftPad - pad).clamp(1.0, 999999.0);
    final colW = ((avail - labelGapX * 2) / 3).clamp(1.0, 999999.0);

    TextPainter tp(String text) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            color: _templateInk,
            fontSize: labelFont,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: colW);
    }

    final tContact = tp('연락처');
    final tSchool = tp('학교');
    final tGrade = tp('학년');
    final tProgress = TextPainter(
      text: const TextSpan(
        text: '진도',
        style: TextStyle(
          color: _templateInk,
          fontSize: labelFont,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: avail);
    final tContent = TextPainter(
      text: const TextSpan(
        text: '상담 내용',
        style: TextStyle(
          color: _templateInk,
          fontSize: 39.0, // 13 * 3
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: avail);

    final x2 = leftPad + colW + labelGapX;
    final x3 = leftPad + colW * 2 + labelGapX * 2;
    tContact.paint(canvas, const Offset(leftPad, y1));
    tSchool.paint(canvas, Offset(x2, y1));
    tGrade.paint(canvas, Offset(x3, y1));

    // 2행: 진도
    tProgress.paint(canvas, Offset(leftPad, y2));

    // 3행: 상담 내용 (3번째 블록 시작점)
    tContent.paint(canvas, Offset(leftPad, y3));
  }

  void _paintStroke(Canvas canvas, Size size, HandwritingStroke s) {
    if (s.points.isEmpty) return;
    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (s.isEraser) {
      paint
        ..blendMode = BlendMode.clear
        ..color = const Color(0x00000000);
    }

    if (s.points.length == 1) {
      final p = _denorm(s.points.first, size);
      final dot = Paint()
        ..color = s.isEraser ? const Color(0x00000000) : s.color
        ..isAntiAlias = true
        ..blendMode = s.isEraser ? BlendMode.clear : BlendMode.srcOver;
      canvas.drawCircle(p, s.width / 2, dot);
      return;
    }

    final path = Path();
    final points = s.points.map((pt) => _denorm(pt, size)).toList(growable: false);
    final first = points.first;
    path.moveTo(first.dx, first.dy);

    // 곡선 스무딩: 중간점 기반 quadratic bezier
    for (int i = 1; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
      path.quadraticBezierTo(p1.dx, p1.dy, mid.dx, mid.dy);
    }
    final last = points.last;
    path.lineTo(last.dx, last.dy);
    canvas.drawPath(path, paint);
  }

  Offset _denorm(HandwritingPoint p, Size size) {
    return Offset(p.nx * size.width, p.ny * size.height);
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.strokes != strokes || oldDelegate.inProgress != inProgress;
  }
}

class _LinePreviewPainter extends CustomPainter {
  final Color color;
  final double width;
  _LinePreviewPainter({required this.color, required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final y = size.height / 2;
    canvas.drawLine(Offset(10, y), Offset(size.width - 10, y), paint);
  }

  @override
  bool shouldRepaint(covariant _LinePreviewPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.width != width;
  }
}


