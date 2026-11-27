import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:ygg_figure/ygg_figure.dart';

import '../../services/figure_files.dart';
import '../../services/figure_sample_print.dart';
import '../../widgets/figure/figure_canvas.dart';
import '../think/think_style.dart';

enum _Tool {
  select('고르기', Icons.near_me_outlined, 0, '점과 글자를 끌어 옮깁니다. 도형을 누르면 고릅니다.'),
  point('점', Icons.fiber_manual_record_outlined, 1, '빈 곳을 눌러 점을 찍습니다.'),
  segment('선분', Icons.horizontal_rule, 2, '두 점을 차례로 누릅니다. 빈 곳을 누르면 그 자리에 점이 생깁니다.'),
  dashed('점선', Icons.more_horiz, 2, '두 점을 차례로 누릅니다. 빈 곳을 누르면 그 자리에 점이 생깁니다.'),
  circle('원', Icons.circle_outlined, 2, '중심을 누르고, 원이 지나갈 자리를 누릅니다.'),
  polygon('다각형', Icons.pentagon_outlined, 0, '꼭짓점을 차례로 누르고, 첫 점을 다시 눌러 닫습니다.'),
  fill('색칠', Icons.format_color_fill, 0, '색칠할 면의 꼭짓점을 차례로 누르고, 첫 점을 다시 눌러 닫습니다.'),
  rightAngle('직각 표시', Icons.crop_square, 3, '한쪽 점, 꼭짓점, 다른 쪽 점을 차례로 누릅니다.'),
  angle('각 표시', Icons.architecture, 3, '한쪽 점, 꼭짓점, 다른 쪽 점을 차례로 누릅니다(반시계 방향).'),
  text('글자', Icons.text_fields, 1, '글자를 놓을 자리를 누릅니다. 내용은 오른쪽에서 고칩니다.');

  const _Tool(this.label, this.icon, this.count, this.hint);
  final String label;
  final IconData icon;

  /// 눌러야 하는 점의 수(0이면 첫 점을 다시 눌러 끝낸다).
  final int count;
  final String hint;
}

const _typeNames = {
  'point': '점', 'on': '도형 위의 점', 'intersect': '만나는 점', 'midpoint': '가운데 점', 'segment': '선분', 'line': '직선',
  'polyline': '꺾은선', 'polygon': '다각형', 'circle': '원', 'arc': '호', 'fill': '색칠', 'right_angle': '직각 표시',
  'angle': '각 표시', 'dimension': '길이 표시', 'label': '글자', 'axes': '좌표축', 'function': '함수 그래프',
};
const _formatLabels = {'assignment': '과제', 'naesin': '내신 (B4)', 'mock': '모의고사 (8절)'};
const _positionLabels = {'below-stem': '본문 아래', 'below-choices': '선지 아래', 'inline-right': '본문 오른쪽'};

/// 그림에 붙이는 이름표: 종류("kind")와 크기 부류("size"."variant").
const _kindLabels = {'plane': '도형', 'graph': '함수', 'solid': '입체', 'solid_graph': '함수 위 입체', 'mapping': '대응'};
const _classLabels = {'small': '소', 'medium': '중', 'large': '대'};

/// 양식별 한 단의 너비(본문 글자 수). 인쇄본을 재서 어림한 값이다.
const _columnEm = {'assignment': 25.05, 'naesin': 28.34, 'mock': 29.53};
const _sampleStem = '그림과 같이 조건을 만족시키는 도형이 있다. 이 글은 그림이 본문과 어떻게 어울리는지 보려고 넣은 보기용 글이다. '
    '실제 문항에서는 이 자리에 문제의 본문이 들어가고, 그림은 고른 양식과 자리의 크기로 다시 그려진다. 구하는 값은?';

/// 그림 편집기. 이 PC 의 그림 파일을 열어 고치고 저장한다(서버·DB 에는 쓰지 않는다).
///
/// 점·글자를 끌어 옮기고, 자주 쓰는 도형을 눌러 더 그린다. "문제 안에서 보기"에서 양식 × 자리의
/// 그림 크기(크기 표)를 눈으로 보고 정한다.
class FigureEditorScreen extends StatefulWidget {
  const FigureEditorScreen({super.key, this.folder, this.embedded = false, this.sampleRunner});

  /// 처음 열 폴더. 없으면 저장소의 수능 그림 폴더를 찾아 연다.
  final String? folder;

  /// 앱의 메뉴 화면 안에 넣을 때 true(위쪽 제목 줄을 그리지 않는다).
  final bool embedded;

  /// 샘플 인쇄본을 만드는 일을 바꿔 끼울 때 쓴다(테스트용). 없으면 이 PC 에서 실제로 만든다.
  final Future<FigureSampleResult> Function(String format)? sampleRunner;

  @override
  State<FigureEditorScreen> createState() => _FigureEditorScreenState();
}

class _FigureEditorScreenState extends State<FigureEditorScreen> {
  FigureFolder? _folder;
  String? _file;
  Map<String, dynamic>? _doc;
  FigureLayout? _layout;
  ({Scene scene, double scale, double widthMm, double heightMm})? _sized;
  final List<String> _undo = [];
  bool _dirty = false;
  bool _tableDirty = false;
  String? _notice;
  bool _noticeIsError = false;

  int _tab = 0;
  _Tool _tool = _Tool.select;
  final List<String> _pending = [];
  String? _picked;
  String? _pickedLabel;
  String _format = 'mock';
  String _position = 'below-stem';

  // 양식에 올려 본 샘플 인쇄본(양식 → 결과, 쪽 그림). 크기나 그림을 바꾸면 "다시 만들어야 함"으로 표시한다.
  final Map<String, FigureSampleResult> _samples = {};
  final Map<String, List<Uint8List>> _samplePages = {};
  final Set<String> _stale = {};
  bool _running = false;
  String? _step;

  @override
  void initState() {
    super.initState();
    final start = widget.folder ?? findRepoFigureFolder();
    if (start != null) _openFolder(start);
  }

  // ---- 파일 ----

  void _say(String? text, {bool error = false}) {
    _notice = text;
    _noticeIsError = error;
  }

  void _openFolder(String path) {
    try {
      _folder = openFigureFolder(path);
      _tableDirty = false;
      _doc = null;
      _file = null;
      _say(null);
      if (_folder!.files.isNotEmpty) _openFile(_folder!.files.first);
    } on Object catch (e) {
      _say('폴더를 열 수 없습니다: $e', error: true);
    }
  }

  void _openFile(String name) {
    try {
      final doc = readFigureFile(_folder!.fileOf(name));
      ensureObjectIds(doc);
      _setDoc(name, doc);
      _dirty = false;
    } on Object catch (e) {
      _say('그림을 열 수 없습니다: $e', error: true);
    }
  }

  void _setDoc(String name, Map<String, dynamic> doc) {
    _layout = layoutFigure(doc);
    _doc = doc;
    _file = name;
    _undo.clear();
    _pending.clear();
    _picked = _pickedLabel = null;
    _say(null);
    _resize();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: '그림 폴더 고르기');
    if (path == null || !mounted || !await _leaveOk()) return;
    setState(() => _openFolder(path));
  }

  Future<bool> _leaveOk() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kThinkPanel,
        shape: thinkDialogShape,
        title: const Text('저장하지 않은 변경이 있습니다', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
        content: const Text('이 그림을 저장하지 않고 넘어가면 고친 내용이 사라집니다.', style: TextStyle(color: kThinkSub, fontSize: 14)),
        actions: [
          OutlinedButton(style: thinkOutlineButton(), onPressed: () => Navigator.pop(context, false), child: const Text('머무르기')),
          ElevatedButton(
            style: thinkPrimaryButton(color: kThinkError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('버리고 넘어가기'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  void _newFigure() {
    final folder = _folder!;
    var n = 1;
    while (folder.files.contains('새그림-$n.json') || File(folder.fileOf('새그림-$n.json')).existsSync()) {
      n++;
    }
    final name = '새그림-$n.json';
    folder.files
      ..add(name)
      ..sort();
    _setDoc(name, newFigureDoc());
    _dirty = true;
    _tab = 0;
  }

  void _save() {
    final folder = _folder!;
    try {
      if (_dirty && _doc != null) writeFigureFile(folder.fileOf(_file!), _doc!);
      if (_tableDirty) writeFigureSizeTable(folder.tablePath, folder.table);
      setState(() {
        _dirty = _tableDirty = false;
        _say('저장했습니다.');
      });
    } on Object catch (e) {
      setState(() => _say('저장하지 못했습니다: $e', error: true));
    }
  }

  // ---- 고치기 ----

  double get _emMm => FigureStyle.byName(_doc?['style'] as String?).bodyPt * mmPerPt;
  FigureSlot? get _slot => _doc == null ? null : _folder?.table.slotFor(_doc!, _format, _position);
  String get _slotKey => '$_format/$_position';

  void _resize() {
    final slot = _slot;
    _sized = slot == null || _doc == null
        ? null
        : sizedSceneEstimate(
            _doc!,
            widthMm: slot.widthEm * _emMm,
            maxHeightMm: slot.maxHeightEm == null ? null : slot.maxHeightEm! * _emMm,
          );
  }

  /// 그림 파일을 고치고 다시 그린다. 그릴 수 없게 되면 고치기 전으로 돌리고 이유를 보여 준다.
  bool _edit(VoidCallback change, {bool remember = true}) {
    final before = jsonEncode(_doc);
    var ok = true;
    setState(() {
      try {
        change();
        _layout = layoutFigure(_doc!);
        _resize();
        // 점만 골랐을 뿐 그림이 그대로면 되돌리기 기록과 저장 표시를 남기지 않는다.
        if (jsonEncode(_doc) != before) {
          if (remember) _remember(before);
          _dirty = true;
          _stale.addAll(_samples.keys);
        }
        _say(null);
      } on Object catch (e) {
        _doc = jsonDecode(before) as Map<String, dynamic>;
        _layout = layoutFigure(_doc!);
        _resize();
        _say('그렇게는 그릴 수 없어 되돌렸습니다: ${e is FigureError ? e.message : e}', error: true);
        ok = false;
      }
    });
    return ok;
  }

  void _remember(String snapshot) {
    _undo.add(snapshot);
    if (_undo.length > 60) _undo.removeAt(0);
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    setState(() {
      _doc = jsonDecode(_undo.removeLast()) as Map<String, dynamic>;
      _layout = layoutFigure(_doc!);
      _resize();
      _pending.clear();
      _picked = _pickedLabel = null;
      _dirty = true;
    });
  }

  List<dynamic> get _objects => (_doc!['objects'] as List?) ?? (_doc!['objects'] = <dynamic>[]);
  double _r(double v) => (v * 1000).round() / 1000;

  String _addPoint(P mm) {
    final id = nextPointName(_doc!);
    final m = _layout!.toMath(mm);
    _objects.add(<String, dynamic>{
      'id': id,
      'type': 'point',
      'at': <dynamic>[_r(m.x), _r(m.y)],
      'label': <String, dynamic>{'dir': 'NE', 'dist': 0.8},
    });
    return id;
  }

  void _add(String prefix, Map<String, dynamic> object) {
    final id = nextObjectId(_doc!, prefix);
    _objects.add(<String, dynamic>{'id': id, ...object});
    _picked = id;
  }

  void _tapCanvas(FigureHit hit) {
    final tool = _tool;
    if (tool == _Tool.select) {
      setState(() {
        _picked = hit.pointId ?? hit.source;
        _pickedLabel = null;
      });
      return;
    }
    final pending = [..._pending];
    final done = _edit(() {
      switch (tool) {
        case _Tool.point:
          _picked = _addPoint(hit.mm);
          return;
        case _Tool.text:
          final m = _layout!.toMath(hit.mm);
          _add('t', {'type': 'label', 'at': <dynamic>[_r(m.x), _r(m.y)], 'text': 'a'});
          return;
        case _Tool.circle when pending.length == 1:
          final r = _layout!.points[pending.first]!.distanceTo(hit.mm) / _layout!.unit;
          _add('c', {'type': 'circle', 'center': pending.first, 'radius': _r(r)});
          pending.clear();
          return;
        default:
          break;
      }
      final id = hit.pointId ?? _addPoint(hit.mm);
      final closing = tool.count == 0 && pending.length >= 3 && id == pending.first;
      if (!closing) pending.add(id);
      if (closing || (tool.count > 0 && tool != _Tool.circle && pending.length == tool.count)) {
        switch (tool) {
          case _Tool.segment:
            _add('s', {'type': 'segment', 'from': pending[0], 'to': pending[1]});
          case _Tool.dashed:
            _add('s', {'type': 'segment', 'from': pending[0], 'to': pending[1], 'line': 'dashed'});
          case _Tool.polygon:
            _add('g', {'type': 'polygon', 'points': <dynamic>[...pending]});
          case _Tool.fill:
            _add('f', {'type': 'fill', 'path': <dynamic>[...pending], 'shade': 0.895});
          case _Tool.rightAngle:
            _add('r', {'type': 'right_angle', 'at': pending[1], 'from': pending[0], 'to': pending[2], 'size': 2.3});
          case _Tool.angle:
            _add('a', {'type': 'angle', 'at': pending[1], 'from': pending[0], 'to': pending[2], 'radius': 5});
          default:
            break;
        }
        pending.clear();
      }
    });
    setState(() {
      _pending
        ..clear()
        ..addAll(done ? pending : const []);
    });
  }

  void _startPointDrag(String id) {
    if (!canMovePoint(_doc!, id)) {
      setState(() => _say('이 점은 다른 도형에서 계산되는 점이라 직접 끌 수 없습니다. 그 도형의 점을 움직여 주세요.'));
      return;
    }
    _remember(jsonEncode(_doc));
    setState(() => _picked = id);
  }

  void _nudge(String key, Offset mm) {
    final nudges = (_doc!['label_nudge'] as Map<String, dynamic>?) ?? (_doc!['label_nudge'] = <String, dynamic>{});
    final now = (nudges[key] as List?) ?? const [0, 0];
    // 그림 파일의 미세 이동은 오른쪽·위쪽이 +다.
    nudges[key] = <dynamic>[_r((now[0] as num) + mm.dx), _r((now[1] as num) - mm.dy)];
  }

  void _delete(String id) {
    _edit(() {
      _objects.removeWhere((o) => (o as Map)['id'] == id);
      (_doc!['label_nudge'] as Map?)?.removeWhere((k, _) => k == id || '$k'.startsWith('$id:'));
      _picked = null;
    });
  }

  /// 이 그림의 크기 부류(소·중·대). 안 적혀 있으면 null(표의 기본 칸 = 중).
  String? get _sizeClass => (_doc?['size'] as Map?)?['variant'] as String?;

  /// 이 그림이 지금 양식·자리에서 쓰는 표의 칸(그림에 따로 적은 값은 보지 않는다).
  FigureSlot? get _tableSlot => _folder?.table.slot(_format, _position, variant: _sizeClass);

  void _setClass(String cls) => _edit(() {
        final size = (_doc!['size'] as Map<String, dynamic>?) ?? (_doc!['size'] = <String, dynamic>{});
        size['variant'] = cls;
      });

  /// 표의 칸을 고친다. 이 그림의 부류에 해당하는 칸이 표에 있으면 그 칸을, 없으면 기본 칸을 고친다.
  /// [widthRatio] 는 본문 너비에 대한 비율(비율로 적힌 칸에서 쓴다).
  void _setSlot({double? widthEm, double? widthRatio, double? maxHeightEm, bool clearHeight = false}) {
    final table = _folder!.table;
    final variant = _tableSlot?.variant;
    final i = table.slots.indexWhere((s) => s.format == _format && s.position == _position && s.variant == variant);
    final old = i < 0 ? null : table.slots[i];
    final column = table.columns[_format];
    final ratio = column == null ? null : (widthRatio ?? (widthEm == null ? old?.widthRatio : null));
    final next = FigureSlot(
      format: _format,
      position: _position,
      variant: variant,
      widthEm: ratio != null ? ratio * column! : (widthEm ?? old?.widthEm ?? 16),
      widthRatio: ratio,
      maxHeightEm: clearHeight ? null : (maxHeightEm ?? old?.maxHeightEm),
      note: old?.note,
    );
    setState(() {
      i < 0 ? table.slots.add(next) : table.slots[i] = next;
      _tableDirty = true;
      _stale.addAll(_samples.keys);
      _resize();
    });
  }

  /// 임시: 지금 폴더의 그림을 고른 양식의 크기 표대로 다시 그려, 샘플 문항을 실제 인쇄 틀에 올려 본다.
  Future<void> _runSamples() async {
    final folder = _folder!;
    final format = _format;
    final runner = widget.sampleRunner;
    final root = runner == null ? findRepoRoot() : null;
    if (runner == null && root == null) {
      setState(() => _say('저장소 폴더 안에서 띄운 앱에서만 인쇄본을 만들 수 있습니다.', error: true));
      return;
    }
    // 인쇄 도구는 파일을 읽으므로, 고친 그림과 크기 표를 먼저 저장한다.
    if (!File(folder.tablePath).existsSync()) _tableDirty = true;
    if (_dirty || _tableDirty) _save();
    if (_dirty || _tableDirty) return;
    setState(() {
      _running = true;
      _step = '준비 중…';
      _say(null);
    });
    try {
      final result = runner != null
          ? await runner(format)
          : await printFigureSamples(
              repoRoot: root!,
              figureFolder: folder.path,
              tablePath: folder.tablePath,
              format: format,
              onStep: (step) {
                if (mounted) setState(() => _step = step);
              },
            );
      final pages = [for (final page in result.pages) File(page).readAsBytesSync()];
      if (!mounted) return;
      setState(() {
        _samples[format] = result;
        _samplePages[format] = pages;
        _stale.remove(format);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _say(e is StateError ? e.message : '$e', error: true));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Map<String, dynamic>? get _own => ((_doc?['size'] as Map?)?['overrides'] as Map?)?[_slotKey] as Map<String, dynamic>?;

  void _setOwn(double? widthEm, {String? note}) {
    final size = (_doc!['size'] as Map<String, dynamic>?) ?? (_doc!['size'] = <String, dynamic>{});
    final overrides = (size['overrides'] as Map<String, dynamic>?) ?? (size['overrides'] = <String, dynamic>{});
    if (widthEm == null) {
      overrides.remove(_slotKey);
      if (overrides.isEmpty) size.remove('overrides');
      if (size.isEmpty) _doc!.remove('size');
      return;
    }
    final text = (note ?? _own?['note'] as String? ?? '').trim();
    overrides[_slotKey] = <String, dynamic>{'width_em': widthEm, if (text.isNotEmpty) 'note': text};
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final folder = _folder;
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: widget.embedded
          ? null
          : AppBar(backgroundColor: kThinkBg, foregroundColor: kThinkText, title: const Text('그림 편집기')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: folder == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_notice != null) ...[ThinkNotice(text: _notice!, color: kThinkError), const SizedBox(height: 16)],
                    const Text('그림 파일이 있는 폴더를 열어 주세요.', style: TextStyle(color: kThinkSub, fontSize: 14)),
                    const SizedBox(height: 16),
                    ElevatedButton(style: thinkPrimaryButton(), onPressed: _pickFolder, child: const Text('폴더 열기')),
                  ],
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 220, child: _fileList(folder)),
                  const SizedBox(width: 16),
                  Expanded(child: _doc == null ? const SizedBox() : _work()),
                  const SizedBox(width: 16),
                  SizedBox(width: 340, child: _doc == null ? const SizedBox() : ListView(children: _tab == 0 ? _editSide() : _sizeSide())),
                ],
              ),
      ),
    );
  }

  Widget _fileList(FigureFolder folder) {
    return ThinkPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(style: thinkOutlineButton(), onPressed: _pickFolder, child: const Text('폴더 열기')),
          const SizedBox(height: 8),
          OutlinedButton(
            style: thinkOutlineButton(),
            onPressed: () async {
              if (await _leaveOk()) setState(_newFigure);
            },
            child: const Text('새 그림'),
          ),
          const SizedBox(height: 12),
          Text('그림 ${folder.files.length}장', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final name in folder.files)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: name == _file
                        ? null
                        : () async {
                            if (await _leaveOk()) setState(() => _openFile(name));
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: name == _file ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${name.replaceAll('.json', '')}${name == _file && _dirty ? ' •' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: name == _file ? kThinkText : kThinkSub, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _work() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ThinkPillTabs(
              labels: const ['그림 고치기', '문제 안에서 보기', '양식에 올려 보기'],
              icons: const [Icons.edit_outlined, Icons.article_outlined, Icons.print_outlined],
              selected: _tab,
              onSelected: (i) => setState(() => _tab = i),
            ),
            OutlinedButton(style: thinkOutlineButton(), onPressed: _undo.isEmpty ? null : _undoOnce, child: const Text('되돌리기')),
            ElevatedButton(style: thinkPrimaryButton(), onPressed: _dirty || _tableDirty ? _save : null, child: const Text('저장')),
          ],
        ),
        const SizedBox(height: 12),
        if (_tab == 0) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _Tool.values)
                ThinkToggleChip(
                  label: t.label,
                  icon: t.icon,
                  selected: _tool == t,
                  tooltip: t.hint,
                  onChanged: (_) => setState(() {
                    _tool = t;
                    _pending.clear();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (_notice != null) ...[
          ThinkNotice(
            text: _notice!,
            color: _noticeIsError ? kThinkError : kThinkBlue,
            icon: _noticeIsError ? Icons.error_outline : Icons.info_outline,
            onClose: () => setState(() => _say(null)),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: ThinkPanel(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, box) => switch (_tab) {
                0 => _figureDesk(box),
                1 => _pageDesk(box),
                _ => _sampleDesk(),
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _tab == 0
              ? '${_tool.label}: ${_tool.hint}${_pending.isEmpty ? '' : '  (찍은 점 ${_pending.join(', ')})'}'
              : _tab == 1
                  ? '크기는 화면에서 어림한 값입니다. 인쇄할 때는 실제로 조판해 잰 크기로 다시 그립니다.'
                  : '실제 인쇄 틀에 올린 모습입니다. 오른쪽에서 크기를 고친 뒤 "다시 만들기"를 누르면 반영됩니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12),
        ),
      ],
    );
  }

  Widget _figureDesk(BoxConstraints box) {
    final layout = _layout!;
    final scene = layout.scene;
    final k = math.max(1.0, math.min(9.0, math.min((box.maxWidth - 48) / scene.width, (box.maxHeight - 48) / scene.height)));
    return Center(
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.all(24),
        child: FigureCanvas(
          scene: scene,
          pxPerMm: k,
          points: layout.points,
          movable: {
            for (final id in layout.points.keys)
              if (canMovePoint(_doc!, id)) id,
          },
          marked: _pending,
          pickedSource: _picked,
          picked: _pickedLabel,
          onPick: (key) => setState(() {
            _pickedLabel = key;
            _picked = null;
          }),
          onLabelDragStart: (_) => _remember(jsonEncode(_doc)),
          onLabelDrag: (key, mm) => _edit(() => _nudge(key, mm), remember: false),
          onPointDragStart: _startPointDrag,
          onPointDrag: (id, mm) {
            if (canMovePoint(_doc!, id)) _edit(() => movePoint(_doc!, id, mm), remember: false);
          },
          onTap: _tapCanvas,
        ),
      ),
    );
  }

  Widget _pageDesk(BoxConstraints box) {
    final sized = _sized;
    if (sized == null) return const Center(child: Text('이 양식·자리의 크기가 표에 없습니다.', style: TextStyle(color: kThinkSub)));
    final columnEm = _folder!.table.columns[_format] ?? _columnEm[_format]!;
    // 양식을 바꿔도 화면 배율은 같게 둔다(가장 넓은 단 기준). 그래야 양식끼리 크기를 견줄 수 있다.
    final k = math.max(1.0, math.min(7.0, (box.maxWidth - 48) / ((_columnEm.values.reduce(math.max) + 2) * _emMm)));
    final em = _emMm * k;
    final body = TextStyle(color: Colors.black, fontSize: em * 0.94, height: 1.7);
    final figure = FigureCanvas(scene: sized.scene, pxPerMm: k);
    final stem = Text.rich(
      TextSpan(children: [
        TextSpan(text: '13. ', style: body.copyWith(fontWeight: FontWeight.w800)),
        const TextSpan(text: _sampleStem),
      ]),
      style: body,
    );
    final choices = Padding(
      padding: EdgeInsets.only(top: em * 0.6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [for (final c in const ['① 1', '② 2', '③ 3', '④ 4', '⑤ 5']) Text(c, style: body)],
      ),
    );
    return SingleChildScrollView(
      child: Center(
        child: Container(
          // 흰 종이 = 한 단. 글이 놓이는 너비가 단 너비이고, 양옆은 종이 여백이다.
          width: (columnEm + 2) * em,
          color: Colors.white,
          padding: EdgeInsets.all(em),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (_position) {
              'inline-right' => [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Expanded(child: stem), SizedBox(width: em * 0.8), figure],
                  ),
                  choices,
                ],
              'below-choices' => [stem, choices, SizedBox(height: em * 0.8), Center(child: figure)],
              _ => [stem, SizedBox(height: em * 0.8), Center(child: figure), choices],
            },
          ),
        ),
      ),
    );
  }

  /// 수능 샘플 문항을 고른 양식의 실제 인쇄 틀에 올린 쪽들.
  Widget _sampleDesk() {
    final pages = _samplePages[_format];
    final result = _samples[_format];
    final name = _formatLabels[_format];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _running
                    ? (_step ?? '')
                    : result == null
                        ? '$name 양식에 수능 샘플 문항을 실제 인쇄 틀로 올려 봅니다. 2~3분 걸립니다.'
                        : '$name · 문항 ${result.questions}개 · ${result.pages.length}쪽'
                            '${result.needsCheck > 0 ? ' · 도형이 많이 달라진 그림 ${result.needsCheck}장' : ''}',
                style: const TextStyle(color: kThinkSub, fontSize: 13),
              ),
            ),
            if (_running) ...[
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
              const SizedBox(width: 12),
            ],
            if (result != null && result.pdf.isNotEmpty) ...[
              OutlinedButton(style: thinkOutlineButton(), onPressed: () => OpenFilex.open(result.pdf), child: const Text('PDF 열기')),
              const SizedBox(width: 8),
            ],
            ElevatedButton(
              style: thinkPrimaryButton(),
              onPressed: _running ? null : _runSamples,
              child: Text(pages == null ? '샘플 20문항 올려 보기 (임시)' : '다시 만들기'),
            ),
          ],
        ),
        if (_stale.contains(_format) && !_running) ...[
          const SizedBox(height: 8),
          const ThinkNotice(
            text: '크기나 그림을 바꿨습니다. "다시 만들기"를 눌러야 아래 인쇄본에 반영됩니다.',
            color: kThinkAccent,
            icon: Icons.warning_amber_outlined,
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: pages == null
              ? const Center(child: Text('아직 만든 인쇄본이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)))
              : ListView.separated(
                  itemCount: pages.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (context, i) => Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Image.memory(pages[i], fit: BoxFit.fitWidth, gaplessPlayback: true),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 값 한 줄: 한 칸씩(글자는 0.1, 비율은 1%) 줄이고 늘리는 단추가 붙는다.
  Widget _stepLine(String label, double value, ValueChanged<double> onChanged, {bool percent = false}) {
    final by = percent ? 1.0 : 0.1;
    final unit = percent ? '%' : ' 글자';
    final name = percent ? '1%' : '0.1 글자';
    void step(double sign) => onChanged(
        percent ? (value + sign * by).roundToDouble().clamp(10.0, 100.0) : (((value + sign * by) * 10).round() / 10).clamp(4.0, 40.0));
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(color: kThinkSub, fontSize: 13))),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          color: kThinkSub,
          tooltip: '$name 줄이기',
          onPressed: () => step(-1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 72,
          child: Text(
            '${value.toStringAsFixed(percent ? 0 : 1)}$unit',
            textAlign: TextAlign.center,
            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          color: kThinkSub,
          tooltip: '$name 늘리기',
          onPressed: () => step(1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  Widget _title(String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800))),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: kThinkSub, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(double value, double min, double max, ValueChanged<double> onChanged, {ValueChanged<double>? onStart}) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: kThinkAccent,
        inactiveTrackColor: kThinkBorder,
        thumbColor: kThinkAccent,
        overlayColor: kThinkAccent.withValues(alpha: 0.16),
        trackHeight: 4,
      ),
      child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged, onChangeStart: onStart),
    );
  }

  List<Widget> _editSide() {
    final id = _picked ?? '';
    final o = id.isEmpty ? null : figureObject(_doc!, id);
    final canvas = _doc!['canvas'] as Map?;
    final type = o?['type'] as String?;
    final pointLabel = o?['label'];
    final text = type == 'label' ? o!['text'] as String? : (pointLabel is Map ? pointLabel['text'] as String? : null);
    final hasText = type == 'label' || (o != null && _layout!.points.containsKey(id));
    return [
      ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title('고른 것', trailing: o == null ? null : ThinkBadge(_typeNames[type] ?? '$type', color: kThinkLink)),
            if (o == null)
              Text(
                _pickedLabel == null ? '고르기로 점이나 도형을 누르면 여기서 고칩니다.' : '글자 "$_pickedLabel" 을(를) 골랐습니다. 끌어서 옮깁니다.',
                style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.4),
              )
            else ...[
              _line('이름', id),
              if (_layout!.points.containsKey(id)) _line('끌어 옮기기', canMovePoint(_doc!, id) ? '됨' : '다른 도형에서 계산됨'),
              if (hasText) ...[
                const SizedBox(height: 8),
                TextFormField(
                  key: ValueKey('text-$id'),
                  initialValue: text ?? (type == 'label' ? '' : id),
                  style: const TextStyle(color: kThinkText, fontSize: 13),
                  decoration: thinkInputDecoration(label: '글자 (수식)', hint: r'예: \mathrm{A}, f(x), \dfrac{\pi}{3}', dense: true),
                  onChanged: (v) => _edit(() {
                    if (type == 'label') {
                      o['text'] = v;
                    } else {
                      o['label'] = <String, dynamic>{...(pointLabel is Map ? pointLabel.cast<String, dynamic>() : {'dir': pointLabel ?? 'NE'}), 'text': v};
                    }
                  }),
                ),
              ],
              if (type == 'segment' || type == 'polygon' || type == 'polyline' || type == 'circle') ...[
                const SizedBox(height: 8),
                ThinkToggleChip(
                  label: '점선',
                  icon: Icons.more_horiz,
                  selected: o['line'] == 'dashed',
                  onChanged: (on) => _edit(() => on ? o['line'] = 'dashed' : o.remove('line')),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton(style: thinkOutlineButton(), onPressed: () => _delete(id), child: const Text('지우기')),
            ],
          ],
        ),
      ),
      if (canvas != null && canvas['width'] is num && canvas['height'] is num) ...[
        const SizedBox(height: 16),
        ThinkPanel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title('그림판'),
              _line('너비', '${(canvas['width'] as num).toStringAsFixed(1)} mm'),
              _slider((canvas['width'] as num).toDouble(), 20, 120, (v) => _edit(() => canvas['width'] = _r(v), remember: false),
                  onStart: (_) => _remember(jsonEncode(_doc))),
              _line('높이', '${(canvas['height'] as num).toStringAsFixed(1)} mm'),
              _slider((canvas['height'] as num).toDouble(), 15, 120, (v) => _edit(() => canvas['height'] = _r(v), remember: false),
                  onStart: (_) => _remember(jsonEncode(_doc))),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _sizeSide() {
    final slot = _slot;
    final sized = _sized;
    final own = _own;
    final em = _emMm;
    final base = _tableSlot;
    final column = _folder!.table.columns[_format];
    final byRatio = base?.widthRatio != null && column != null;
    // 부류마다 칸이 따로 있는 자리에서만 부류 이름을 제목에 붙인다.
    final classed = base?.variant != null || _folder!.table.slots.any((s) => s.format == _format && s.position == _position && s.variant != null);
    final className = _classLabels[_sizeClass ?? 'medium'] ?? '중';
    return [
      ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title('양식과 자리'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in figureFormats)
                  ThinkToggleChip(
                    label: _formatLabels[f]!,
                    icon: Icons.description_outlined,
                    selected: _format == f,
                    onChanged: (_) => setState(() {
                      _format = f;
                      _resize();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in figurePositions)
                  ThinkToggleChip(
                    label: _positionLabels[p]!,
                    icon: p == 'inline-right' ? Icons.align_horizontal_right : Icons.align_vertical_bottom,
                    selected: _position == p,
                    onChanged: (_) => setState(() {
                      _position = p;
                      _resize();
                    }),
                  ),
              ],
            ),
            if (sized != null) ...[
              const SizedBox(height: 16),
              _line('이 그림의 크기', '${(sized.widthMm / em).toStringAsFixed(1)} × ${(sized.heightMm / em).toStringAsFixed(1)} 글자'),
              _line('도형 배율', '×${sized.scale.toStringAsFixed(2)}'),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title('이 그림의 이름표'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in _kindLabels.entries)
                  ThinkToggleChip(
                    label: k.value,
                    icon: Icons.category_outlined,
                    selected: _doc?['kind'] == k.key,
                    onChanged: (_) => _edit(() => _doc!['kind'] = k.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _classLabels.entries)
                  ThinkToggleChip(
                    label: c.value,
                    icon: Icons.photo_size_select_small,
                    selected: _sizeClass == c.key,
                    tooltip: '크기 부류: ${c.value}',
                    onChanged: (_) => _setClass(c.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '소·중·대는 본문 아래·선지 아래 자리의 너비를 정합니다. 본문 오른쪽 자리는 한 크기입니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(classed ? '크기 표 · $className (모든 그림)' : '크기 표 (모든 그림)',
                trailing: _tableDirty ? const ThinkBadge('저장 전', color: kThinkAccent) : null),
            if (byRatio) ...[
              _stepLine('본문 너비의', base!.widthRatio! * 100, (v) => _setSlot(widthRatio: v / 100), percent: true),
              _slider(base.widthRatio! * 100, 10, 100, (v) => _setSlot(widthRatio: v.roundToDouble() / 100)),
              _line('너비', '${base.widthEm.toStringAsFixed(1)} 글자 (본문 ${column.toStringAsFixed(1)} 글자)'),
            ] else ...[
              _stepLine('너비', base?.widthEm ?? 16, (v) => _setSlot(widthEm: v)),
              _slider(base?.widthEm ?? 16, 6, 30, (v) => _setSlot(widthEm: (v * 10).round() / 10)),
            ],
            if (base?.maxHeightEm == null)
              _line('높이 한도', '없음')
            else ...[
              _stepLine('높이 한도', base!.maxHeightEm!, (v) => _setSlot(maxHeightEm: v)),
              _slider(base.maxHeightEm!, 6, 30, (v) => _setSlot(maxHeightEm: (v * 10).round() / 10)),
            ],
            ThinkToggleChip(
              label: '높이 한도 쓰기',
              icon: Icons.height,
              selected: base?.maxHeightEm != null,
              tooltip: '세로로 긴 그림이 이 높이를 넘으면 너비 대신 높이에 맞춥니다',
              onChanged: (on) => on ? _setSlot(maxHeightEm: base?.widthEm ?? 16) : _setSlot(clearHeight: true),
            ),
            const SizedBox(height: 8),
            Text(
              classed
                  ? '여기서 정한 크기는 이 양식·이 자리에 실리는 "$className" 그림 모두에 적용됩니다.'
                  : '여기서 정한 크기는 이 양식·이 자리에 실리는 모든 그림에 적용됩니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title('이 그림만', trailing: own == null ? null : const ThinkBadge('희귀 케이스', color: kThinkAccent)),
            ThinkToggleChip(
              label: '이 그림만 따로 정함',
              icon: Icons.push_pin_outlined,
              selected: own != null,
              tooltip: '이 양식·이 자리에서 이 그림의 크기만 따로 정합니다',
              onChanged: (on) => _edit(() => _setOwn(on ? (slot?.widthEm ?? 16) : null)),
            ),
            if (own != null && slot != null) ...[
              _stepLine('너비', slot.widthEm, (v) => _edit(() => _setOwn(v))),
              _slider(slot.widthEm, 6, 30, (v) => _edit(() => _setOwn((v * 10).round() / 10), remember: false),
                  onStart: (_) => _remember(jsonEncode(_doc))),
              TextFormField(
                key: ValueKey('note-$_file-$_slotKey'),
                initialValue: own['note'] as String? ?? '',
                style: const TextStyle(color: kThinkText, fontSize: 13),
                decoration: thinkInputDecoration(label: '따로 정한 이유', hint: '예: 표의 크기로는 글자가 겹친다', dense: true),
                onChanged: (v) => _edit(() => _setOwn(slot.widthEm, note: v), remember: false),
              ),
            ],
          ],
        ),
      ),
    ];
  }
}
