import 'dart:async';
import 'dart:math' as math;
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

enum _TextBoxDragMode { none, move, resizeTL, resizeTR, resizeBL, resizeBR }

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
  String? _trialMiniSelectedSlotId; // 하단 미니바에서 선택 중인 시범 슬롯(id)

  // 텍스트 박스 선택/편집(이동/리사이즈)
  String? _selectedTextBoxId;
  String? _editingTextBoxId;
  _TextBoxDragMode _textBoxDragMode = _TextBoxDragMode.none;
  bool _textBoxDragStarted = false;
  bool _textBoxTapWasAlreadySelected = false;
  Rect? _textBoxDragStartRectN; // 0..1
  Offset? _textBoxDragStartLocal; // px

  Widget _buildTrialMiniBar() {
    final noteId = _note?.id;
    if (noteId == null || noteId.isEmpty) return const SizedBox.shrink();

    const trialGreen = Color(0xFF4CAF50);

    String pad2(int v) => v.toString().padLeft(2, '0');
    String weekLabel(DateTime d) {
      const week = ['월', '화', '수', '목', '금', '토', '일'];
      return week[(d.weekday - 1).clamp(0, 6)];
    }
    String fmtHm(DateTime d) => '${pad2(d.hour)}:${pad2(d.minute)}';
    DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

    // 희망 수업 요약(오른쪽) - 2줄(윗줄=라벨, 아랫줄=요일/시간)
    ({String title, String times}) desiredSummary2(ConsultNote n) {
      final slots = n.desiredSlots.isNotEmpty
          ? n.desiredSlots
          : ((n.desiredWeekday != null && n.desiredHour != null && n.desiredMinute != null)
              ? [
                  ConsultDesiredSlot(
                    dayIndex: (n.desiredWeekday! - 1).clamp(0, 6),
                    hour: n.desiredHour!,
                    minute: n.desiredMinute!,
                  )
                ]
              : const <ConsultDesiredSlot>[]);
      final title = (n.desiredStartWeek != null)
          ? '희망(${n.desiredStartWeek!.month}/${n.desiredStartWeek!.day}~)'
          : '희망';
      if (slots.isEmpty) return (title: title, times: '-');
      final sorted = [...slots]..sort((a, b) {
        final d = a.dayIndex.compareTo(b.dayIndex);
        if (d != 0) return d;
        final ta = a.hour * 60 + a.minute;
        final tb = b.hour * 60 + b.minute;
        return ta.compareTo(tb);
      });
      const w = ['월', '화', '수', '목', '금', '토', '일'];
      String item(ConsultDesiredSlot s) => '${w[s.dayIndex.clamp(0, 6)]} ${pad2(s.hour)}:${pad2(s.minute)}';
      final shown = sorted.take(3).map(item).toList(growable: false);
      final extra = (sorted.length > 3) ? ' +${sorted.length - 3}' : '';
      return (title: title, times: '${shown.join(' · ')}$extra');
    }

    return ValueListenableBuilder<List<ConsultTrialLessonSlot>>(
      valueListenable: ConsultTrialLessonService.instance.slotsNotifier,
      builder: (context, all, _) {
        final slots = all.where((s) => s.sourceNoteId == noteId).toList();
        if (slots.isEmpty) return const SizedBox.shrink();

        slots.sort((a, b) {
          final wa = dateOnly(a.weekStart);
          final wb = dateOnly(b.weekStart);
          final w = wa.compareTo(wb);
          if (w != 0) return w;
          final da = a.dayIndex.compareTo(b.dayIndex);
          if (da != 0) return da;
          final ta = (a.hour * 60 + a.minute);
          final tb = (b.hour * 60 + b.minute);
          final t = ta.compareTo(tb);
          if (t != 0) return t;
          return a.id.compareTo(b.id);
        });

        // 표시 우선순위: (등원O,하원X) 진행중 → (등원X) 예정 → 마지막(완료)
        ConsultTrialLessonSlot pick = slots.first;
        final forcedIdx = (_trialMiniSelectedSlotId == null)
            ? -1
            : slots.indexWhere((s) => s.id == _trialMiniSelectedSlotId);
        if (forcedIdx != -1) {
          pick = slots[forcedIdx];
        } else {
          for (final s in slots) {
            if (s.arrivalTime != null && s.departureTime == null) {
              pick = s;
              break;
            }
          }
          if (pick.arrivalTime == null) {
            for (final s in slots) {
              if (s.arrivalTime == null) {
                pick = s;
                break;
              }
            }
          }
        }

        final wk = dateOnly(pick.weekStart);
        final slotDate = dateOnly(wk.add(Duration(days: pick.dayIndex)));
        final schedule = '${slotDate.month}/${slotDate.day}(${weekLabel(slotDate)}) ${pad2(pick.hour)}:${pad2(pick.minute)}';
        final int pickIdx = slots.indexWhere((s) => s.id == pick.id);
        final extra = (slots.length > 1 && pickIdx != -1) ? ' (${pickIdx + 1}/${slots.length})' : '';

        final arr = pick.arrivalTime?.toLocal();
        final dep = pick.departureTime?.toLocal();
        final arrText = arr == null ? '등원 -' : '등원 ${fmtHm(arr)}';
        final depText = dep == null ? '하원 -' : '하원 ${fmtHm(dep)}';
        final arrColor = (arr == null) ? Colors.white54 : const Color(0xFF66BB6A);
        final depColor = (dep == null) ? Colors.white54 : const Color(0xFF66BB6A);
        final wish2 = desiredSummary2(_note!);

        void cycleNext() {
          if (slots.length <= 1) return;
          final curIdx = (pickIdx == -1) ? 0 : pickIdx;
          final next = slots[(curIdx + 1) % slots.length];
          setState(() {
            _trialMiniSelectedSlotId = next.id;
          });
        }

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: cycleNext,
            borderRadius: BorderRadius.circular(28),
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.white.withValues(alpha: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  height: 56,
                  // ✅ 줄간격 "조금" 늘림(오버플로우는 유지)
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                  decoration: BoxDecoration(
                    color: const Color(0xCC10171A),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: _border),
                  ),
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 시범(왼쪽)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: trialGreen.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: trialGreen.withOpacity(0.32)),
                        ),
                        child: const Text(
                          '시범',
                          style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 12, fontWeight: FontWeight.w900, height: 1.05),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        fit: FlexFit.loose,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$schedule$extra',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _text, fontSize: 13, fontWeight: FontWeight.w900, height: 1.08),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(arrText, style: TextStyle(color: arrColor, fontSize: 12, fontWeight: FontWeight.w800, height: 1.08)),
                                const SizedBox(width: 10),
                                Text(depText, style: TextStyle(color: depColor, fontSize: 12, fontWeight: FontWeight.w800, height: 1.08)),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // 희망(오른쪽)
                      const SizedBox(width: 12),
                      Container(width: 1, height: 30, color: Colors.white10),
                      const SizedBox(width: 12),
                      Flexible(
                        fit: FlexFit.loose,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              wish2.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _text, fontSize: 13.5, fontWeight: FontWeight.w900, height: 1.05),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              wish2.times,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.05),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

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
  bool _textMode = false; // ✅ 텍스트 입력 모드

  // 텍스트 박스
  List<ConsultTextBox> _textBoxes = <ConsultTextBox>[];
  Offset? _textDragStartN;
  Rect? _textDraftRectN; // 0..1 normalized
  Rect? _textEditingRectN; // 편집 중인 영역(0..1 normalized)
  TextEditingController? _textEditingCtrl;
  FocusNode? _textEditingFocus;

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
      _textBoxes = [...note.textBoxes];
      _inProgress = null;
      _textDraftRectN = null;
      _textEditingRectN = null;
      _trialMiniSelectedSlotId = null;
      _selectedTextBoxId = null;
      _editingTextBoxId = null;
      _textBoxDragMode = _TextBoxDragMode.none;
      _textBoxDragStarted = false;
      _textBoxTapWasAlreadySelected = false;
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
      _textBoxes = [...bootNote.textBoxes];
      _inProgress = null;
      _textDraftRectN = null;
      _textEditingRectN = null;
      _trialMiniSelectedSlotId = null;
      _selectedTextBoxId = null;
      _editingTextBoxId = null;
      _textBoxDragMode = _TextBoxDragMode.none;
      _textBoxDragStarted = false;
      _textBoxTapWasAlreadySelected = false;
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
      textBoxes: const <ConsultTextBox>[],
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
        textBoxes: List<ConsultTextBox>.unmodifiable(_textBoxes),
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
    if (_strokes.isEmpty && _textBoxes.isEmpty) return;
    setState(() {
      _strokes = <HandwritingStroke>[];
      _inProgress = null;
      _textBoxes = <ConsultTextBox>[];
      _textDraftRectN = null;
      _textEditingRectN = null;
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
      _textMode = false;
      if (value) {
        // 요구사항: 지우개 선택 시 기본 두께는 40
        _eraserWidth = 40.0;
      }
    });
  }

  void _setTextMode() {
    setState(() {
      _textMode = true;
      _eraser = false;
      _textDraftRectN = null;
    });
  }

  double _textFontSizeByBoxHeightPx(double hPx) {
    // 박스 높이가 커지면 폰트도 커지도록(요청사항)
    final avail = (hPx - 20.0).clamp(1.0, 999999.0); // 편집 박스 내부 padding(대략) 고려
    return (avail * 0.52).clamp(12.0, 200.0);
  }

  ConsultTextBox? _hitTextBox(Offset local, Size size) {
    // 위에 그려진 박스가 우선(뒤에서부터 검사)
    for (int i = _textBoxes.length - 1; i >= 0; i--) {
      final b = _textBoxes[i];
      final r = Rect.fromLTWH(
        b.nx * size.width,
        b.ny * size.height,
        b.nw * size.width,
        b.nh * size.height,
      );
      if (r.contains(local)) return b;
    }
    return null;
  }

  _TextBoxDragMode _hitTextBoxHandle(Offset local, Rect rectPx) {
    // UX: 리사이즈가 잘 안 잡히는 문제 → 핸들 히트 영역을 넓힌다.
    const handleR = 14.0;
    bool near(Offset c) => (local - c).distance <= handleR;
    if (near(rectPx.topLeft)) return _TextBoxDragMode.resizeTL;
    if (near(rectPx.topRight)) return _TextBoxDragMode.resizeTR;
    if (near(rectPx.bottomLeft)) return _TextBoxDragMode.resizeBL;
    if (near(rectPx.bottomRight)) return _TextBoxDragMode.resizeBR;
    return _TextBoxDragMode.move;
  }

  Rect _clampRectN(Rect r) {
    const minW = 0.03;
    const minH = 0.03;
    double l = r.left;
    double t = r.top;
    double rr = r.right;
    double bb = r.bottom;
    // 정렬(역전 방지)
    final left = math.min(l, rr);
    final right = math.max(l, rr);
    final top = math.min(t, bb);
    final bottom = math.max(t, bb);
    l = left;
    rr = right;
    t = top;
    bb = bottom;
    // 최소 크기
    if (rr - l < minW) rr = l + minW;
    if (bb - t < minH) bb = t + minH;
    // clamp
    l = l.clamp(0.0, 1.0);
    t = t.clamp(0.0, 1.0);
    rr = rr.clamp(0.0, 1.0);
    bb = bb.clamp(0.0, 1.0);
    // 다시 최소 크기 보장(우측/하단 clamp로 줄었을 수 있음)
    if (rr - l < minW) {
      if (l + minW <= 1.0) {
        rr = l + minW;
      } else {
        l = (rr - minW).clamp(0.0, 1.0);
      }
    }
    if (bb - t < minH) {
      if (t + minH <= 1.0) {
        bb = t + minH;
      } else {
        t = (bb - minH).clamp(0.0, 1.0);
      }
    }
    return Rect.fromLTRB(l, t, rr, bb);
  }

  void _deleteTextBoxById(String id) {
    setState(() {
      _textBoxes = _textBoxes.where((b) => b.id != id).toList(growable: false);
      if (_selectedTextBoxId == id) _selectedTextBoxId = null;
      if (_editingTextBoxId == id) _editingTextBoxId = null;
      _dirty = true;
    });
  }

  Widget _buildTextBoxDeleteOverlay(Size size) {
    if (!_textMode) return const SizedBox.shrink();
    if (_textEditingRectN != null) return const SizedBox.shrink();
    final selId = _selectedTextBoxId;
    if (selId == null || selId.isEmpty) return const SizedBox.shrink();
    ConsultTextBox? b;
    for (final x in _textBoxes) {
      if (x.id == selId) {
        b = x;
        break;
      }
    }
    if (b == null) return const SizedBox.shrink();
    final rectPx = Rect.fromLTWH(
      b.nx * size.width,
      b.ny * size.height,
      b.nw * size.width,
      b.nh * size.height,
    );
    const double btn = 26;
    final left = (rectPx.right - btn / 2).clamp(0.0, size.width - btn);
    final top = (rectPx.top - btn / 2).clamp(0.0, size.height - btn);
    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _deleteTextBoxById(selId),
          borderRadius: BorderRadius.circular(999),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.white.withValues(alpha: 16),
          child: Container(
            width: btn,
            height: btn,
            decoration: BoxDecoration(
              color: const Color(0xCC10171A),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.redAccent.withValues(alpha: 166), width: 1.2),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
              ],
            ),
            child: const Center(
              child: Icon(Icons.close_rounded, size: 16, color: Colors.redAccent),
            ),
          ),
        ),
      ),
    );
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
    if (_textEditingRectN != null) return; // 편집 중에는 드로잉 비활성
    if (_textMode) {
      // ✅ 삭제(X) 버튼 클릭 시, 캔버스 Listener가 먼저 상태를 바꿔서 탭이 취소되는 문제 방지
      // - X 버튼 영역이면 여기서는 아무것도 하지 않고, 오버레이의 InkWell 탭만 처리되게 둔다.
      final selId = _selectedTextBoxId;
      if (selId != null && selId.isNotEmpty) {
        ConsultTextBox? sel;
        for (final b in _textBoxes) {
          if (b.id == selId) {
            sel = b;
            break;
          }
        }
        if (sel != null) {
          final rectPx = Rect.fromLTWH(
            sel.nx * size.width,
            sel.ny * size.height,
            sel.nw * size.width,
            sel.nh * size.height,
          );
          const double btn = 26;
          final left = (rectPx.right - btn / 2).clamp(0.0, size.width - btn);
          final top = (rectPx.top - btn / 2).clamp(0.0, size.height - btn);
          final btnRect = Rect.fromLTWH(left, top, btn, btn);
          if (btnRect.contains(e.localPosition)) {
            return;
          }
        }
      }

      _activePointer = e.pointer;
      // ✅ 기존 텍스트 박스 클릭 → 선택 + 이동/리사이즈
      final hit = _hitTextBox(e.localPosition, size);
      if (hit != null) {
        final wasAlreadySelected = (_selectedTextBoxId == hit.id);
        final rectPx = Rect.fromLTWH(
          hit.nx * size.width,
          hit.ny * size.height,
          hit.nw * size.width,
          hit.nh * size.height,
        );
        final mode = _hitTextBoxHandle(e.localPosition, rectPx);
        setState(() {
          _selectedTextBoxId = hit.id;
          _textBoxDragMode = mode;
          _textBoxDragStarted = false;
          _textBoxTapWasAlreadySelected = wasAlreadySelected;
          _textBoxDragStartRectN = Rect.fromLTWH(hit.nx, hit.ny, hit.nw, hit.nh);
          _textBoxDragStartLocal = e.localPosition;
          _textDraftRectN = null;
          _textDragStartN = null;
        });
        return;
      }
      // ✅ 새 텍스트 박스 생성(드래그 영역)
      final p = _toNormalizedOffset(e.localPosition, size);
      setState(() {
        _selectedTextBoxId = null;
        _textBoxDragMode = _TextBoxDragMode.none;
        _textBoxDragStarted = false;
        _textBoxTapWasAlreadySelected = false;
        _textBoxDragStartRectN = null;
        _textBoxDragStartLocal = null;
        _textDragStartN = p;
        _textDraftRectN = Rect.fromLTWH(p.dx, p.dy, 0, 0);
      });
      return;
    }
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
    if (_textMode) {
      // 기존 박스 이동/리사이즈 중
      final selId = _selectedTextBoxId;
      final startRectN = _textBoxDragStartRectN;
      final startLocal = _textBoxDragStartLocal;
      if (selId != null && startRectN != null && startLocal != null && _textBoxDragMode != _TextBoxDragMode.none) {
        final dist = (e.localPosition - startLocal).distance;
        // "한 번 더 클릭해서 편집" UX를 위해, 아주 작은 움직임은 드래그로 취급하지 않는다.
        if (!_textBoxDragStarted && dist < 3.5) return;
        if (!_textBoxDragStarted) {
          setState(() {
            _textBoxDragStarted = true;
          });
        }
        final dxN = (e.localPosition.dx - startLocal.dx) / (size.width <= 1 ? 1.0 : size.width);
        final dyN = (e.localPosition.dy - startLocal.dy) / (size.height <= 1 ? 1.0 : size.height);
        Rect next = startRectN;
        switch (_textBoxDragMode) {
          case _TextBoxDragMode.move:
            next = Rect.fromLTWH(startRectN.left + dxN, startRectN.top + dyN, startRectN.width, startRectN.height);
            break;
          case _TextBoxDragMode.resizeTL:
            next = Rect.fromLTRB(startRectN.left + dxN, startRectN.top + dyN, startRectN.right, startRectN.bottom);
            break;
          case _TextBoxDragMode.resizeTR:
            next = Rect.fromLTRB(startRectN.left, startRectN.top + dyN, startRectN.right + dxN, startRectN.bottom);
            break;
          case _TextBoxDragMode.resizeBL:
            next = Rect.fromLTRB(startRectN.left + dxN, startRectN.top, startRectN.right, startRectN.bottom + dyN);
            break;
          case _TextBoxDragMode.resizeBR:
            next = Rect.fromLTRB(startRectN.left, startRectN.top, startRectN.right + dxN, startRectN.bottom + dyN);
            break;
          case _TextBoxDragMode.none:
            break;
        }
        next = _clampRectN(next);
        setState(() {
          _textBoxes = _textBoxes
              .map((b) => (b.id == selId) ? b.copyWith(nx: next.left, ny: next.top, nw: next.width, nh: next.height) : b)
              .toList(growable: false);
          _dirty = true;
        });
        return;
      }

      // 새 박스 드래그
      final start = _textDragStartN;
      if (start == null) return;
      final cur = _toNormalizedOffset(e.localPosition, size);
      final left = math.min(start.dx, cur.dx);
      final top = math.min(start.dy, cur.dy);
      final right = math.max(start.dx, cur.dx);
      final bottom = math.max(start.dy, cur.dy);
      setState(() {
        _textDraftRectN = Rect.fromLTRB(left, top, right, bottom);
      });
      return;
    }
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
    if (_textMode) {
      // 박스 이동/리사이즈 종료
      if (_selectedTextBoxId != null && _textBoxDragMode != _TextBoxDragMode.none) {
        final selId = _selectedTextBoxId!;
        final mode = _textBoxDragMode;
        final didDrag = _textBoxDragStarted;
        final shouldEdit = (!didDrag && _textBoxTapWasAlreadySelected && mode == _TextBoxDragMode.move);
        ConsultTextBox? editBox;
        if (shouldEdit) {
          for (final b in _textBoxes) {
            if (b.id == selId) {
              editBox = b;
              break;
            }
          }
        }
        setState(() {
          _activePointer = null;
          _textBoxDragMode = _TextBoxDragMode.none;
          _textBoxDragStartRectN = null;
          _textBoxDragStartLocal = null;
          _textBoxDragStarted = false;
          _textBoxTapWasAlreadySelected = false;
          if (editBox != null) {
            final b = editBox;
            _editingTextBoxId = b.id;
            _textEditingRectN = Rect.fromLTWH(b.nx, b.ny, b.nw, b.nh);
            _textEditingCtrl = TextEditingController(text: b.text);
            _textEditingFocus = FocusNode();
          }
        });
        if (editBox != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _textEditingFocus?.requestFocus();
          });
        }
        return;
      }

      final rectN = _textDraftRectN;
      setState(() {
        _activePointer = null;
        _textDragStartN = null;
        _textDraftRectN = null;
      });
      if (rectN == null) return;
      // 너무 작은 영역은 무시
      if (rectN.width < 0.02 || rectN.height < 0.02) return;
      setState(() {
        _editingTextBoxId = null;
        _textEditingRectN = rectN;
        _textEditingCtrl = TextEditingController();
        _textEditingFocus = FocusNode();
      });
      // 포커스는 프레임 이후에
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _textEditingFocus?.requestFocus();
      });
      return;
    }
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
      _textDragStartN = null;
      _textDraftRectN = null;
      _textBoxDragMode = _TextBoxDragMode.none;
      _textBoxDragStartRectN = null;
      _textBoxDragStartLocal = null;
      _textBoxDragStarted = false;
      _textBoxTapWasAlreadySelected = false;
    });
  }

  Offset _toNormalizedOffset(Offset local, Size size) {
    final w = size.width <= 1 ? 1.0 : size.width;
    final h = size.height <= 1 ? 1.0 : size.height;
    double nx = local.dx / w;
    double ny = local.dy / h;
    if (nx.isNaN || nx.isInfinite) nx = 0;
    if (ny.isNaN || ny.isInfinite) ny = 0;
    nx = nx.clamp(0.0, 1.0);
    ny = ny.clamp(0.0, 1.0);
    return Offset(nx, ny);
  }

  void _commitTextEdit() {
    final rectN = _textEditingRectN;
    final ctrl = _textEditingCtrl;
    if (rectN == null || ctrl == null) return;
    final text = ctrl.text.trimRight();
    final editId = _editingTextBoxId;
    setState(() {
      if (text.trim().isNotEmpty) {
        if (editId != null && editId.isNotEmpty) {
          _textBoxes = _textBoxes
              .map((b) => (b.id == editId)
                  ? b.copyWith(
                      nx: rectN.left,
                      ny: rectN.top,
                      nw: rectN.width,
                      nh: rectN.height,
                      text: text,
                    )
                  : b)
              .toList(growable: false);
          _selectedTextBoxId = editId;
        } else {
          final id = const Uuid().v4();
          _textBoxes = [
            ..._textBoxes,
            ConsultTextBox(
              id: id,
              nx: rectN.left,
              ny: rectN.top,
              nw: rectN.width,
              nh: rectN.height,
              text: text,
              colorArgb: _penColor.toARGB32(),
            ),
          ];
          _selectedTextBoxId = id;
        }
        _dirty = true;
      } else {
        // 편집 중이었다면 빈 값 = 삭제 처리
        if (editId != null && editId.isNotEmpty) {
          _textBoxes = _textBoxes.where((b) => b.id != editId).toList(growable: false);
          if (_selectedTextBoxId == editId) _selectedTextBoxId = null;
          _dirty = true;
        }
      }
      _editingTextBoxId = null;
      _textEditingRectN = null;
      _textEditingCtrl?.dispose();
      _textEditingCtrl = null;
      _textEditingFocus?.dispose();
      _textEditingFocus = null;
    });
  }

  void _cancelTextEdit() {
    setState(() {
      _editingTextBoxId = null;
      _textEditingRectN = null;
      _textEditingCtrl?.dispose();
      _textEditingCtrl = null;
      _textEditingFocus?.dispose();
      _textEditingFocus = null;
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
              onPressed: (_strokes.isNotEmpty || _textBoxes.isNotEmpty) ? _clearAll : null,
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
        // ✅ 하단 고정 바: 도구모음은 중앙(기존 위치 유지), 시범 요약은 하단 왼쪽
        bottomNavigationBar: _loading
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SizedBox(
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(alignment: Alignment.centerLeft, child: _buildTrialMiniBar()),
                        Align(
                          alignment: Alignment.center,
                          child: _BottomDrawFabBar(
                            eraser: _eraser,
                            textMode: _textMode,
                            penColor: _penColor,
                            penWidth: _penWidth,
                            eraserWidth: _eraserWidth,
                            onSelectPen: () => _setEraser(false),
                            onSelectEraser: () => _setEraser(true),
                            onSelectText: _setTextMode,
                            onPickColor: () => unawaited(_pickPenColor()),
                            onPickWidth: () => unawaited(_pickPenWidth()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
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
                              child: Stack(
                                children: [
                                  CustomPaint(
                                    painter: _HandwritingPainter(
                                      strokes: _strokes,
                                      inProgress: _inProgress,
                                      textBoxes: _textBoxes,
                                      textDraftRectN: _textDraftRectN,
                                      selectedTextBoxId: _selectedTextBoxId,
                                      showTextBoxHandles: _textMode,
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                  _buildTextBoxDeleteOverlay(size),
                                  if (_textEditingRectN != null && _textEditingCtrl != null && _textEditingFocus != null)
                                    Positioned.fromRect(
                                      rect: Rect.fromLTWH(
                                        _textEditingRectN!.left * size.width,
                                        _textEditingRectN!.top * size.height,
                                        _textEditingRectN!.width * size.width,
                                        _textEditingRectN!.height * size.height,
                                      ),
                                      child: Builder(builder: (ctx2) {
                                        final pad = (_textEditingRectN!.height * size.height * 0.08).clamp(6.0, 14.0);
                                        return Material(
                                          color: Colors.transparent,
                                          child: Container(
                                            padding: EdgeInsets.fromLTRB(pad, pad, 44, pad),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0B1112).withOpacity(0.92),
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(color: _accent, width: 2),
                                            ),
                                            child: Stack(
                                              children: [
                                                TextField(
                                                  controller: _textEditingCtrl,
                                                  focusNode: _textEditingFocus,
                                                  maxLines: null,
                                                  expands: true,
                                                  style: TextStyle(
                                                    color: Color(_penColor.toARGB32()),
                                                    fontSize: _textFontSizeByBoxHeightPx(_textEditingRectN!.height * size.height),
                                                    fontWeight: FontWeight.w800,
                                                    height: 1.18,
                                                  ),
                                                  cursorColor: _accent,
                                                  decoration: const InputDecoration(
                                                    border: InputBorder.none,
                                                    isDense: true,
                                                    contentPadding: EdgeInsets.zero,
                                                  ),
                                                ),
                                                Positioned(
                                                  top: 0,
                                                  right: 0,
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      _BottomToolIcon(
                                                        tooltip: '확인',
                                                        onTap: _commitTextEdit,
                                                        padding: const EdgeInsets.all(4),
                                                        child: const Icon(Icons.check_rounded, size: 18, color: _accent),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      _BottomToolIcon(
                                                        tooltip: '취소',
                                                        onTap: _cancelTextEdit,
                                                        padding: const EdgeInsets.all(4),
                                                        child: const Icon(Icons.close_rounded, size: 18, color: Colors.white70),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                    ),
                                ],
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
  final bool textMode;
  final Color penColor;
  final double penWidth;
  final double eraserWidth;
  final VoidCallback onSelectPen;
  final VoidCallback onSelectEraser;
  final VoidCallback onSelectText;
  final VoidCallback onPickColor;
  final VoidCallback onPickWidth;

  const _BottomDrawFabBar({
    required this.eraser,
    required this.textMode,
    required this.penColor,
    required this.penWidth,
    required this.eraserWidth,
    required this.onSelectPen,
    required this.onSelectEraser,
    required this.onSelectText,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xCC10171A),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: _border),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 16, offset: Offset(0, 6)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
                  _BottomToolToggle(
                    selected: (!eraser && !textMode),
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
                  const SizedBox(width: 8),
                  _BottomToolToggle(
                    selected: textMode,
                    label: '텍스트',
                    width: 92,
                    bg: const Color(0xFF1976D2),
                    icon: Icons.text_fields_rounded,
                    onTap: onSelectText,
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
  final List<ConsultTextBox> textBoxes;
  final Rect? textDraftRectN;
  final String? selectedTextBoxId;
  final bool showTextBoxHandles;

  _HandwritingPainter({
    required this.strokes,
    required this.inProgress,
    this.textBoxes = const <ConsultTextBox>[],
    this.textDraftRectN,
    this.selectedTextBoxId,
    this.showTextBoxHandles = false,
  });

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

    // 텍스트 박스(타자) - 지우개 영향 없이 레이어 밖에 그린다.
    for (final b in textBoxes) {
      if (b.text.trim().isEmpty) continue;
      final r = Rect.fromLTWH(
        b.nx * size.width,
        b.ny * size.height,
        b.nw * size.width,
        b.nh * size.height,
      );
      if (r.width <= 1 || r.height <= 1) continue;
      // 박스 높이에 따라 글자 크기도 같이 커지도록 (요청사항)
      final pad = (r.height * 0.08).clamp(4.0, 14.0);
      final inner = Rect.fromLTWH(
        r.left + pad,
        r.top + pad,
        (r.width - pad * 2).clamp(1.0, 999999.0),
        (r.height - pad * 2).clamp(1.0, 999999.0),
      );
      final fontSize = (inner.height * 0.52).clamp(12.0, 200.0);
      final tp = TextPainter(
        text: TextSpan(
          text: b.text,
          style: TextStyle(
            color: Color(b.colorArgb),
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            height: 1.18,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: inner.width);
      canvas.save();
      canvas.clipRect(r);
      tp.paint(canvas, inner.topLeft);
      canvas.restore();
    }

    // 선택된 텍스트 박스(이동/리사이즈) 표시
    if (showTextBoxHandles && selectedTextBoxId != null) {
      final b = textBoxes.firstWhere(
        (x) => x.id == selectedTextBoxId,
        orElse: () => const ConsultTextBox(
          id: '',
          nx: 0,
          ny: 0,
          nw: 0,
          nh: 0,
          text: '',
          colorArgb: 0,
        ),
      );
      if (b.id.isNotEmpty && b.nw > 0 && b.nh > 0) {
        final r = Rect.fromLTWH(
          b.nx * size.width,
          b.ny * size.height,
          b.nw * size.width,
          b.nh * size.height,
        );
        final border = Paint()
          ..color = _accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)), border);

        const handle = 6.0;
        final fill = Paint()..color = _accent;
        void drawHandle(Offset c) {
          canvas.drawCircle(c, handle, fill);
          canvas.drawCircle(
            c,
            handle + 2,
            Paint()
              ..color = Colors.black.withValues(alpha: 60)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }

        drawHandle(r.topLeft);
        drawHandle(r.topRight);
        drawHandle(r.bottomLeft);
        drawHandle(r.bottomRight);
      }
    }

    // 텍스트 영역 드래그 선택 표시
    final draft = textDraftRectN;
    if (draft != null && draft.width > 0 && draft.height > 0) {
      final r = Rect.fromLTWH(
        draft.left * size.width,
        draft.top * size.height,
        draft.width * size.width,
        draft.height * size.height,
      );
      final p = Paint()
        ..color = _accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)), p);
    }
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
    return oldDelegate.strokes != strokes ||
        oldDelegate.inProgress != inProgress ||
        oldDelegate.textBoxes != textBoxes ||
        oldDelegate.textDraftRectN != textDraftRectN ||
        oldDelegate.selectedTextBoxId != selectedTextBoxId ||
        oldDelegate.showTextBoxHandles != showTextBoxHandles;
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


