import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:uuid/uuid.dart';

import '../../models/consult_note.dart';
import '../../services/consult_note_controller.dart';
import '../../services/consult_note_service.dart';

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

  // 펜 설정
  Color _penColor = Colors.white;
  double _penWidth = 3.6;
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
    note ??= _newBlankNote();
    setState(() {
      _note = note;
      _strokes = [...note!.strokes];
      _inProgress = null;
      _dirty = false;
      _loading = false;
    });
  }

  ConsultNote _newBlankNote({String? title}) {
    final now = DateTime.now();
    return ConsultNote(
      id: const Uuid().v4(),
      title: (title == null || title.trim().isEmpty) ? '상담 노트' : title.trim(),
      createdAt: now,
      updatedAt: now,
      strokes: const <HandwritingStroke>[],
    );
  }

  Future<bool> _confirmHandleDirtyIfNeeded() async {
    if (!_dirty) return true;
    final action = await showDialog<_DirtyAction>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF2A2A2A)),
        );
        final btnShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: shape,
          titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          contentPadding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          actionsPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          title: const Row(
            children: [
              Icon(Icons.save_outlined, color: Colors.white70, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '저장하지 않은 변경사항',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          content: const Text(
            '현재 노트에 저장하지 않은 내용이 있습니다.\n저장할까요?',
            style: TextStyle(color: Colors.white70, height: 1.35, fontWeight: FontWeight.w700),
          ),
          actions: [
            SizedBox(
              height: 44,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: Colors.white70,
                  shape: btnShape,
                ),
                onPressed: () => Navigator.of(ctx).pop(_DirtyAction.cancel),
                child: const Text('취소', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            SizedBox(
              height: 44,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent.withValues(alpha: 64),
                  foregroundColor: Colors.white,
                  shape: btnShape,
                ),
                onPressed: () => Navigator.of(ctx).pop(_DirtyAction.discard),
                child: const Text('버리기', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            SizedBox(
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1976D2),
                  foregroundColor: Colors.white,
                  shape: btnShape,
                ),
                onPressed: () => Navigator.of(ctx).pop(_DirtyAction.save),
                child: const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        );
      },
    );

    if (action == _DirtyAction.save) {
      await _save();
      return true;
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
      if (!mounted) return;
      setState(() {
        _note = updated;
        _dirty = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장되었습니다.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('저장에 실패했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _newNoteFlow() async {
    final ok = await _confirmHandleDirtyIfNeeded();
    if (!ok) return;
    final created = _newBlankNote();
    setState(() {
      _note = created;
      _strokes = <HandwritingStroke>[];
      _inProgress = null;
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
    final metas = await ConsultNoteService.instance.listMetas();
    ConsultNote? next;
    if (metas.isNotEmpty) {
      next = await ConsultNoteService.instance.load(metas.first.id);
    }
    next ??= _newBlankNote();
    if (!mounted) return;
    setState(() {
      _note = next;
      _strokes = [...next!.strokes];
      _inProgress = null;
      _dirty = false;
    });
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

  void _onCheckSchedulePressed() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('일정 확인 기능은 준비 중입니다.')));
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
    double temp = _penWidth;
    final picked = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('펜 두께', style: TextStyle(color: Colors.white)),
          content: StatefulBuilder(builder: (ctx2, setSB) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: temp.clamp(1.0, 18.0),
                  min: 1.0,
                  max: 18.0,
                  divisions: 17,
                  activeColor: const Color(0xFF1976D2),
                  label: temp.toStringAsFixed(1),
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
                        painter: _LinePreviewPainter(color: _eraser ? _bg : _penColor, width: temp),
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
    setState(() => _penWidth = picked);
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
        width: _penWidth,
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
    final title = _note?.title ?? '상담 노트';
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
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          actions: [
            IconButton(
              tooltip: '새 노트',
              onPressed: _loading ? null : () => unawaited(_newNoteFlow()),
              icon: const Icon(Icons.note_add_outlined),
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
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                  _ToolBar(
                    penColor: _penColor,
                    eraser: _eraser,
                    penWidth: _penWidth,
                    canUndo: _strokes.isNotEmpty,
                    canClear: _strokes.isNotEmpty,
                    onPickColor: () => unawaited(_pickPenColor()),
                    onPickWidth: () => unawaited(_pickPenWidth()),
                    onSetEraser: (v) => setState(() => _eraser = v),
                    onCheckSchedule: _onCheckSchedulePressed,
                    onUndo: _undo,
                    onClear: _clearAll,
                    onSave: (_saving || _note == null) ? null : () => unawaited(_save()),
                  ),
                ],
              ),
      ),
    );
  }
}

enum _DirtyAction { save, discard, cancel }
enum _MoreAction { rename, delete }

class _ToolBar extends StatelessWidget {
  final Color penColor;
  final bool eraser;
  final double penWidth;
  final bool canUndo;
  final bool canClear;
  final VoidCallback onPickColor;
  final VoidCallback onPickWidth;
  final ValueChanged<bool> onSetEraser;
  final VoidCallback onCheckSchedule;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback? onSave;

  const _ToolBar({
    required this.penColor,
    required this.eraser,
    required this.penWidth,
    required this.canUndo,
    required this.canClear,
    required this.onPickColor,
    required this.onPickWidth,
    required this.onSetEraser,
    required this.onCheckSchedule,
    required this.onUndo,
    required this.onClear,
    required this.onSave,
  });

  Widget _bigPill({
    required VoidCallback? onPressed,
    required Widget child,
    Color? bg,
    Color? fg,
  }) {
    return SizedBox(
      height: 52,
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          backgroundColor: bg ?? Colors.white10,
          foregroundColor: fg ?? Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: onPressed,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: Color(0x22223131))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(children: [
        // 펜 / 지우개 토글
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bigPill(
                onPressed: () => onSetEraser(false),
                bg: !eraser ? _accent : Colors.transparent,
                fg: !eraser ? Colors.white : Colors.white70,
                child: const Row(
                  children: [
                    Icon(Icons.edit, size: 18),
                    SizedBox(width: 6),
                    Text('펜', style: TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _bigPill(
                onPressed: () => onSetEraser(true),
                bg: eraser ? Colors.redAccent.withValues(alpha: 96) : Colors.transparent,
                fg: eraser ? Colors.white : Colors.white70,
                child: const Row(
                  children: [
                    Icon(Icons.auto_fix_off, size: 18),
                    SizedBox(width: 6),
                    Text('지우개', style: TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _bigPill(
          onPressed: onPickColor,
          child: Row(
            children: [
              const Icon(Icons.palette_outlined, size: 20),
              const SizedBox(width: 8),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: penColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
              ),
              const SizedBox(width: 10),
              const Text('색상', style: TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _bigPill(
          onPressed: onPickWidth,
          child: Row(
            children: [
              const Icon(Icons.line_weight, size: 20),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 18,
                child: CustomPaint(
                  painter: _LinePreviewPainter(color: penColor, width: penWidth),
                ),
              ),
              const SizedBox(width: 10),
              Text('두께 ${penWidth.toStringAsFixed(1)}', style: const TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const Spacer(),
        _bigPill(
          onPressed: onCheckSchedule,
          child: const Row(
            children: [
              Icon(Icons.event_note_outlined, size: 20),
              SizedBox(width: 8),
              Text('일정', style: TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const Spacer(),
        _bigPill(
          onPressed: canUndo ? onUndo : null,
          child: const Row(
            children: [
              Icon(Icons.undo, size: 20),
              SizedBox(width: 8),
              Text('되돌리기', style: TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _bigPill(
          onPressed: canClear ? onClear : null,
          child: const Row(
            children: [
              Icon(Icons.delete_sweep_outlined, size: 20),
              SizedBox(width: 8),
              Text('전체삭제', style: TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: onSave,
            icon: const Icon(Icons.save, size: 20),
            label: const Text('저장', style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
      ]),
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
    // 요청사항:
    // - 템플릿의 "줄"은 모두 제거(구분선/밑줄/줄노트/박스 테두리 등).
    // - 1행: 연락처, 학교, 학년
    // - 2행: 진도
    // - 3행: 상담 내용
    // - 템플릿 글자는 3배 크게(기존 12~13px -> 36~39px 수준) + 더 잘 보이는 회색

    const double labelFont = 36.0; // 12 * 3
    const double labelGapX = 18.0;
    // 세로 배치 비율: 1 : 1 : 2 (총 4등분)
    const top = pad;
    final bottom = size.height - pad;
    final totalH = (bottom - top).clamp(1.0, 999999.0);
    final unit = totalH / 4.0;
    const y1 = top;
    final y2 = top + unit * 1.0;
    final y3 = top + unit * 2.0;

    final w = size.width;
    final avail = (w - pad * 2).clamp(1.0, 999999.0);
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

    final x2 = pad + colW + labelGapX;
    final x3 = pad + colW * 2 + labelGapX * 2;
    tContact.paint(canvas, const Offset(pad, y1));
    tSchool.paint(canvas, Offset(x2, y1));
    tGrade.paint(canvas, Offset(x3, y1));

    // 2행: 진도
    tProgress.paint(canvas, Offset(pad, y2));

    // 3행: 상담 내용 (3번째 블록 시작점)
    tContent.paint(canvas, Offset(pad, y3));
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


