import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ygg_figure/ygg_figure.dart';

import '../../../../widgets/figure/figure_canvas.dart';
import '../../../think/think_style.dart';
import 'figure_editor_preview_mock.dart';

/// 그림 편집 Preview (목업 데이터만, 서버·저장 없음).
///
/// 그림은 그림 엔진이 계산한 조각을 그대로 그린다. 크기를 바꾸면 도형만 커지고 글자·선 굵기는 그대로다.
/// 화면의 글자체는 인쇄본과 다르다(인쇄는 본문 글꼴로 조판한다).
class FigureEditorPreviewScreen extends StatefulWidget {
  const FigureEditorPreviewScreen({super.key});

  @override
  State<FigureEditorPreviewScreen> createState() => _FigureEditorPreviewScreenState();
}

class _FigureEditorPreviewScreenState extends State<FigureEditorPreviewScreen> {
  int _figure = 0;
  int _tab = 0;
  String _format = 'mock';
  String _position = 'below-stem';
  bool _approved = false;
  String? _picked;
  String? _error;

  late Map<String, dynamic> _doc;
  late ({Scene scene, double scale, double widthMm, double heightMm}) _sized;

  /// 양식·자리마다 따로 적는 미세 이동(글자 수 기준).
  final Map<String, Offset> _shift = {};
  final _note = TextEditingController();

  FigureMock get _mock => figureMocks[_figure];
  String get _slotKey => '$_format/$_position';
  double get _emMm => FigureStyle.byName(_doc['style'] as String?).bodyPt * mmPerPt;
  FigureSlot get _slot => figureMockSizeTable.slotFor(_doc, _format, _position)!;

  @override
  void initState() {
    super.initState();
    _doc = _mock.newDoc();
    _sized = _draw();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  ({Scene scene, double scale, double widthMm, double heightMm}) _draw() {
    final slot = _slot;
    return sizedSceneEstimate(
      _doc,
      widthMm: slot.widthEm * _emMm,
      maxHeightMm: slot.maxHeightEm == null ? null : slot.maxHeightEm! * _emMm,
    );
  }

  /// 그림 파일을 고친 뒤 다시 그린다. 그릴 수 없는 값이면 직전 그림을 남기고 이유를 보여 준다.
  void _change(VoidCallback edit) {
    setState(() {
      edit();
      try {
        _sized = _draw();
        _error = null;
      } on Object catch (e) {
        _error = '이 값으로는 그릴 수 없습니다: $e';
      }
    });
  }

  void _openFigure(int index) {
    _figure = index;
    _doc = _mock.newDoc();
    _shift.clear();
    _picked = null;
    _approved = false;
    _note.text = '';
  }

  Map<String, dynamic>? get _own => ((_doc['size'] as Map?)?['overrides'] as Map?)?[_slotKey] as Map<String, dynamic>?;

  void _setOwn(double? widthEm) {
    final size = (_doc['size'] as Map<String, dynamic>?) ?? (_doc['size'] = <String, dynamic>{});
    final overrides = (size['overrides'] as Map<String, dynamic>?) ?? (size['overrides'] = <String, dynamic>{});
    if (widthEm == null) {
      overrides.remove(_slotKey);
    } else {
      overrides[_slotKey] = <String, dynamic>{'width_em': widthEm, if (_note.text.trim().isNotEmpty) 'note': _note.text.trim()};
    }
  }

  void _nudge(String key, Offset mm) {
    final nudges = (_doc['label_nudge'] as Map<String, dynamic>?) ?? (_doc['label_nudge'] = <String, dynamic>{});
    final now = (nudges[key] as List?) ?? const [0, 0];
    // 그림 파일의 미세 이동은 오른쪽·위쪽이 +다.
    nudges[key] = [(now[0] as num) + mm.dx, (now[1] as num) - mm.dy];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(backgroundColor: kThinkBg, foregroundColor: kThinkText, title: const Text('그림 편집 Preview')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _work()),
            const SizedBox(width: 16),
            SizedBox(width: 340, child: _side()),
          ],
        ),
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
              labels: const ['그림 고치기', '문제 안에서 보기'],
              icons: const [Icons.edit_outlined, Icons.article_outlined],
              selected: _tab,
              onSelected: (i) => setState(() => _tab = i),
            ),
            const SizedBox(width: 8),
            for (var i = 0; i < figureMocks.length; i++)
              ThinkToggleChip(
                label: figureMocks[i].title,
                icon: Icons.category_outlined,
                selected: _figure == i,
                onChanged: (_) => _change(() => _openFigure(i)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: ThinkPanel(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(builder: (context, box) => _tab == 0 ? _figureDesk(box) : _pageDesk(box)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _tab == 0
              ? '글자를 끌면 그 글자만 옮겨집니다. 점은 오른쪽 "모양" 칸에서 움직이고, 이어진 선과 표시는 따라옵니다.'
              : '그림을 끌면 이 양식·이 자리에서만 조금 옮겨집니다. 다른 양식의 자리는 그대로입니다.',
          style: const TextStyle(color: kThinkHint, fontSize: 12),
        ),
      ],
    );
  }

  /// 그림만 크게 놓고 고치는 자리.
  Widget _figureDesk(BoxConstraints box) {
    final scene = _sized.scene;
    final k = math.min(8.0, math.min((box.maxWidth - 48) / scene.width, (box.maxHeight - 48) / scene.height));
    return Center(
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.all(24),
        child: FigureCanvas(
          scene: scene,
          pxPerMm: math.max(1.0, k),
          picked: _picked,
          onPick: (key) => setState(() => _picked = key),
          onLabelDrag: (key, mm) => _change(() => _nudge(key, mm)),
        ),
      ),
    );
  }

  /// 문제 한 개를 실제 단 너비로 놓고 그림의 자리를 보는 곳.
  Widget _pageDesk(BoxConstraints box) {
    final columnEm = figureMockColumnEm[_format]!;
    // 양식을 바꿔도 화면 배율은 같게 둔다(가장 넓은 단 기준). 그래야 양식끼리 크기를 견줄 수 있다.
    final widest = figureMockColumnEm.values.reduce(math.max);
    final k = math.max(1.0, math.min(7.0, (box.maxWidth - 48) / (widest * _emMm)));
    final em = _emMm * k;
    final shift = _shift[_slotKey] ?? Offset.zero;
    final body = TextStyle(color: Colors.black, fontSize: em * 0.94, height: 1.7);

    final figure = MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => setState(() => _shift[_slotKey] = shift + d.delta / em),
        child: Transform.translate(
          offset: shift * em,
          child: FigureCanvas(scene: _sized.scene, pxPerMm: k),
        ),
      ),
    );
    final stem = Text.rich(
      TextSpan(children: [
        TextSpan(text: '13. ', style: body.copyWith(fontWeight: FontWeight.w800)),
        TextSpan(text: '${_mock.stem} (보기용 글)'),
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

  Widget _side() {
    return ListView(
      children: [
        _sizePanel(),
        const SizedBox(height: 16),
        _shapePanel(),
        const SizedBox(height: 16),
        _statePanel(),
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

  Widget _slider(double value, double min, double max, ValueChanged<double> onChanged) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: kThinkAccent,
        inactiveTrackColor: kThinkBorder,
        thumbColor: kThinkAccent,
        overlayColor: kThinkAccent.withValues(alpha: 0.16),
        trackHeight: 4,
      ),
      child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
    );
  }

  Widget _sizePanel() {
    final slot = _slot;
    final own = _own;
    final shift = _shift[_slotKey] ?? Offset.zero;
    final em = _emMm;
    final farOff = _sized.scale < 0.65 || _sized.scale > 1.6;
    return ThinkPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('크기와 자리', trailing: own == null ? null : const ThinkBadge('희귀 케이스', color: kThinkAccent)),
          const Text('양식', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in figureFormats)
                ThinkToggleChip(
                  label: figureMockFormatLabels[f]!,
                  icon: Icons.description_outlined,
                  selected: _format == f,
                  onChanged: (_) => _change(() => _format = f),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('자리', style: TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in figurePositions)
                ThinkToggleChip(
                  label: figureMockPositionLabels[p]!,
                  icon: p == 'inline-right' ? Icons.align_horizontal_right : Icons.align_vertical_bottom,
                  selected: _position == p,
                  onChanged: (_) => _change(() => _position = p),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _line(own == null ? '표에서 정한 너비' : '이 그림만 정한 너비', '${slot.widthEm.toStringAsFixed(1)} 글자'),
          _line('실제 그림', '${(_sized.widthMm / em).toStringAsFixed(1)} × ${(_sized.heightMm / em).toStringAsFixed(1)} 글자'),
          _line('도형 배율', '×${_sized.scale.toStringAsFixed(2)}'),
          _line('미세 이동', '가로 ${shift.dx.toStringAsFixed(1)} · 세로 ${shift.dy.toStringAsFixed(1)} 글자'),
          if (farOff) ...[
            const SizedBox(height: 8),
            const ThinkNotice(
              text: '도형이 원래보다 많이 달라졌습니다. 글자가 겹치지 않는지 확인이 필요합니다.',
              color: kThinkAccent,
              icon: Icons.warning_amber_outlined,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ThinkToggleChip(
                label: '이 그림만 따로 정함',
                icon: Icons.push_pin_outlined,
                selected: own != null,
                tooltip: '이 양식·이 자리에서 이 그림의 크기만 따로 정합니다',
                onChanged: (on) => _change(() => _setOwn(on ? slot.widthEm : null)),
              ),
              if (shift != Offset.zero)
                OutlinedButton(
                  style: thinkOutlineButton(),
                  onPressed: () => setState(() => _shift.remove(_slotKey)),
                  child: const Text('자리 되돌리기'),
                ),
            ],
          ),
          if (own != null) ...[
            _slider(slot.widthEm, 6, 28, (v) => _change(() => _setOwn((v * 2).round() / 2))),
            TextField(
              controller: _note,
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(label: '따로 정한 이유', hint: '예: 평면이 넓어 표의 크기로는 글자가 겹친다', dense: true),
              onChanged: (_) => _change(() => _setOwn(slot.widthEm)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shapePanel() {
    final params = (_doc['params'] as Map).cast<String, dynamic>();
    final nudge = _picked == null ? null : (_doc['label_nudge'] as Map?)?[_picked] as List?;
    return ThinkPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('모양'),
          for (final h in _mock.handles) ...[
            Text(h.label, style: const TextStyle(color: kThinkSub, fontSize: 13)),
            _slider((params[h.param] as num).toDouble(), h.min, h.max, (v) => _change(() => params[h.param] = v)),
          ],
          const SizedBox(height: 4),
          _line(
            '고른 글자',
            _picked == null
                ? '없음'
                : '$_picked · 가로 ${((nudge?[0] ?? 0) as num).toStringAsFixed(2)} · 세로 ${((nudge?[1] ?? 0) as num).toStringAsFixed(2)} mm',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: thinkOutlineButton(),
            onPressed: () => _change(() {
              final first = _mock.newDoc();
              _doc['params'] = first['params'];
              _doc['label_nudge'] = first['label_nudge'];
              _picked = null;
            }),
            child: const Text('모양·글자 처음으로'),
          ),
        ],
      ),
    );
  }

  Widget _statePanel() {
    return ThinkPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('상태', trailing: _approved ? const ThinkBadge('승인됨', color: kThinkSuccess) : const ThinkBadge('초안', color: kThinkLink)),
          const Text(
            '승인한 그림만 인쇄와 앱에 쓰입니다. 원본 그림은 지우지 않습니다.',
            style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: thinkOutlineButton(),
                  onPressed: _approved ? () => setState(() => _approved = false) : null,
                  child: const Text('초안으로'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  style: thinkPrimaryButton(),
                  onPressed: _approved || _error != null ? null : () => setState(() => _approved = true),
                  child: const Text('승인'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
