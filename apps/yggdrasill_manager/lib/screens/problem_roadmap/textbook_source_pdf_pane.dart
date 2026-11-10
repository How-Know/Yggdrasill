import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/textbook_problem_review_service.dart';
import '../../services/textbook_review_solution_image_service.dart';

const Color _kPanelBg = Color(0xFF1C1C1E);
const Color _kFieldBg = Color(0xFF2C2C2E);
const Color _kBorder = Color(0x22FFFFFF);
const Color _kText = Color(0xFFEAF2F2);
const Color _kTextSub = Color(0xFF9FB3B3);
const Color _kTextMuted = Color(0xFF6E7E7E);
const Color _kAccent = Color(0xFF33A373);
const Color _kChipSelected = Color(0xFF1B6B63);
const Color _kBlue = Color(0xFF64B5F6);
const Color _kError = Color(0xFFE57373);
const Color _kWarn = Color(0xFFE0B35A);

/// 운영자가 원본 PDF 에서 드래그로 고른 영역
class TextbookSourceSelection {
  const TextbookSourceSelection({required this.sourceKind, required this.rawPage, required this.region1k});

  /// 'ans' 정답 PDF · 'sol' 해설 PDF · 'body' 본문 PDF
  final String sourceKind;
  final int rawPage;

  /// [ymin, xmin, ymax, xmax] 0..1000
  final List<int> region1k;
}

/// 2단계 작업 화면 오른쪽: 고른 문항의 정답지·해설지·본문 PDF 를 띄우고,
/// AI 가 정답·해설 위치를 못 찾았거나 틀렸을 때 드래그로 직접 지정한다.
class TextbookSourcePdfPane extends StatefulWidget {
  const TextbookSourcePdfPane({
    super.key,
    required this.service,
    required this.scope,
    required this.item,
    required this.allItems,
    required this.busy,
    required this.onSaveAnswerImage,
    required this.onSaveAnswerText,
    required this.onSaveSolution,
    required this.onMarkNoSolution,
  });

  final TextbookProblemReviewService service;
  final TextbookReviewUnitScope scope;
  final TextbookProblemReviewItem item;
  final List<TextbookProblemReviewItem> allItems;
  final bool busy;
  final Future<void> Function(TextbookSourceSelection sel) onSaveAnswerImage;
  final Future<void> Function(TextbookSourceSelection sel, String text, String kind) onSaveAnswerText;
  final Future<void> Function(TextbookSourceSelection sel) onSaveSolution;
  final Future<void> Function() onMarkNoSolution;

  @override
  State<TextbookSourcePdfPane> createState() => _TextbookSourcePdfPaneState();
}

class _TextbookSourcePdfPaneState extends State<TextbookSourcePdfPane> {
  static const _kinds = ['ans', 'sol', 'body'];

  Map<String, int> _pageCounts = const {};
  bool _loadingCounts = true;
  String _kind = 'sol';
  int _page = 1;
  final _pageCtrl = TextEditingController(text: '1');

  final Map<String, Future<TextbookReviewRenderedRegion?>> _pageCache = {};
  TextbookReviewRenderedRegion? _rendered;
  bool _loadingPage = false;
  String? _error;
  int _loadSeq = 0;

  Offset? _dragStart;
  Offset? _dragNow;
  List<int>? _selection;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void didUpdateWidget(covariant TextbookSourcePdfPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope.key != widget.scope.key) {
      _pageCache.clear();
      unawaited(_init());
      return;
    }
    if (oldWidget.item.cropId != widget.item.cropId) _jumpToItem();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loadingCounts = true);
    final counts = await Future.wait([
      for (final k in _kinds) widget.service.sourcePageCount(widget.scope, k).catchError((Object _) => 0),
    ]);
    if (!mounted) return;
    setState(() {
      _pageCounts = {for (var i = 0; i < _kinds.length; i++) _kinds[i]: counts[i]};
      _loadingCounts = false;
    });
    _jumpToItem();
  }

  bool _hasKind(String kind) => (_pageCounts[kind] ?? 0) > 0;

  String _defaultKind(TextbookProblemReviewItem it) {
    if (it.existingAnswer.trim().isEmpty && _hasKind('ans')) return 'ans';
    if (it.hasSolutionRef && it.solutionSourceKind == 'body') return 'body';
    if (_hasKind('sol')) return 'sol';
    if (_hasKind('ans')) return 'ans';
    return 'body';
  }

  /// 이 문항(없으면 같은 소단원·가까운 쪽 문항)의 저장된 쪽
  int? _nearestPage(int? Function(TextbookProblemReviewItem x) pick) {
    final it = widget.item;
    final own = pick(it);
    if (own != null && own > 0) return own;
    int? best;
    var bestDist = 1 << 30;
    for (final o in widget.allItems) {
      final p = pick(o);
      if (p == null || p <= 0) continue;
      final dist = (o.rawPage - it.rawPage).abs() * 10 + (o.subKey == it.subKey ? 0 : 5);
      if (dist < bestDist) {
        bestDist = dist;
        best = p;
      }
    }
    return best;
  }

  int _defaultPage(String kind) {
    final it = widget.item;
    final p = switch (kind) {
      'ans' => _nearestPage((x) => x.answerRawPage),
      'sol' => _nearestPage((x) => x.hasSolutionRef && x.solutionSourceKind == 'sol' ? x.solutionRawPage : null),
      _ => it.solutionSourceKind == 'body' && (it.solutionRawPage ?? 0) > 0 ? it.solutionRawPage : it.rawPage,
    };
    final max = _pageCounts[kind] ?? 0;
    final page = (p ?? 1) < 1 ? 1 : (p ?? 1);
    return max > 0 && page > max ? max : page;
  }

  void _jumpToItem({String? kind}) {
    if (_loadingCounts) return;
    final k = kind ?? _defaultKind(widget.item);
    _kind = k;
    _selection = null;
    unawaited(_loadPage(_defaultPage(k)));
  }

  Future<void> _loadPage(int page) async {
    final max = _pageCounts[_kind] ?? 0;
    final target = math.max(1, max > 0 ? math.min(page, max) : page);
    final seq = ++_loadSeq;
    setState(() {
      _page = target;
      _pageCtrl.text = '$target';
      _loadingPage = true;
      _error = null;
      _selection = null;
    });
    final key = '$_kind|$target';
    final kind = _kind;
    final future = _pageCache.putIfAbsent(
      key,
      () => widget.service
          .renderSourcePage(scope: widget.scope, sourceKind: kind, rawPage: target)
          .then<TextbookReviewRenderedRegion?>((r) => r, onError: (Object _) => null),
    );
    final r = await future;
    if (r == null) _pageCache.remove(key);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _rendered = r;
      _loadingPage = false;
      if (r == null) _error = '${_kindLabel(kind)} PDF $target쪽을 그리지 못했습니다.';
    });
  }

  static String _kindLabel(String kind) => switch (kind) {
        'ans' => '정답지',
        'sol' => '해설지',
        _ => '본문',
      };

  Offset _norm(Offset local, Size size) => Offset(
        (local.dx / math.max(1.0, size.width)).clamp(0.0, 1.0),
        (local.dy / math.max(1.0, size.height)).clamp(0.0, 1.0),
      );

  void _commitDrag(Offset a, Offset b) {
    final xmin = (math.min(a.dx, b.dx) * 1000).round().clamp(0, 995);
    final xmax = (math.max(a.dx, b.dx) * 1000).round().clamp(xmin + 5, 1000);
    final ymin = (math.min(a.dy, b.dy) * 1000).round().clamp(0, 995);
    final ymax = (math.max(a.dy, b.dy) * 1000).round().clamp(ymin + 5, 1000);
    if (xmax - xmin < 10 || ymax - ymin < 6) return;
    setState(() => _selection = [ymin, xmin, ymax, xmax]);
  }

  TextbookSourceSelection? get _currentSelection {
    final s = _selection;
    if (s == null) return null;
    return TextbookSourceSelection(sourceKind: _kind, rawPage: _page, region1k: s);
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() => _selection = null);
  }

  Future<void> _promptAnswerText(TextbookSourceSelection sel) async {
    final ctrl = TextEditingController(text: widget.item.isImageAnswer ? '' : widget.item.existingAnswer);
    var kind = RegExp(r'^[①-⑩](\s*,\s*[①-⑩])*$').hasMatch(ctrl.text.trim()) ? 'objective' : 'subjective';
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanelBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: const BorderSide(color: _kBorder),
          ),
          title: Text(
            '${widget.item.problemNumber}번 정답 입력',
            style: const TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_kindLabel(sel.sourceKind)} ${sel.rawPage}쪽에서 고른 영역을 근거로 저장합니다.',
                  style: const TextStyle(color: _kTextSub, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (value, label) in const [('objective', '객관식'), ('subjective', '주관식')])
                      _choice(label, kind == value, () => setLocal(() => kind = value)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: kind == 'objective' ? 1 : 3,
                  minLines: 1,
                  style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    hintText: kind == 'objective' ? '예: ③' : r'예: $x=2$ 또는 풀이 참조',
                    hintStyle: const TextStyle(color: _kTextMuted, fontSize: 13),
                    filled: true,
                    fillColor: _kFieldBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _kBorder),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소', style: TextStyle(color: _kTextSub)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kAccent, shape: const StadiumBorder()),
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isEmpty) return;
                Navigator.of(ctx).pop((text, kind));
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    await _run(() => widget.onSaveAnswerText(sel, result.$1, result.$2));
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected : _kFieldBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? _kAccent : _kBorder, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(color: selected ? _kText : _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
      );

  Widget _action(String label, IconData icon, Color color, VoidCallback? onTap, {bool filled = false}) {
    final enabled = onTap != null;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: filled && enabled ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: enabled ? color.withValues(alpha: filled ? 1 : 0.7) : _kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: !enabled ? _kTextMuted : (filled ? Colors.white : color)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: !enabled ? _kTextMuted : (filled ? Colors.white : color),
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_Box> _boxesForPage() {
    final it = widget.item;
    return [
      if (_kind == 'ans' && it.canCropAnswer && it.answerRawPage == _page) _Box(it.answerBbox1k, _kBlue, '저장된 정답'),
      if (it.canCropSolution && it.solutionSourceKind == _kind && it.solutionRawPage == _page)
        _Box(it.solutionRegion1k, _kAccent, '저장된 해설'),
      if (_kind == 'body' && it.canRenderOriginal && it.rawPage == _page) _Box(it.itemRegion1k, _kTextSub, '문항'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final sel = _currentSelection;
    final busy = widget.busy || _loadingPage;
    final answerLabel = it.existingAnswer.trim().isEmpty
        ? '정답 없음'
        : it.isImageAnswer
            ? '그림 정답${it.answerManual ? ' (직접 지정)' : ''}'
            : '정답 ${it.existingAnswer.trim()}${it.answerManual ? ' (직접 입력)' : ''}';
    final solutionLabel = it.solutionMarkedNone
        ? '해설 없음'
        : it.hasSolutionRef
            ? '해설 ${_kindLabel(it.solutionSourceKind)} ${it.solutionRawPage ?? '-'}쪽'
            : '해설 위치 없음';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _kBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.picture_as_pdf_outlined, color: _kAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '원본 PDF — ${it.problemNumber}번',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kText, fontSize: 14.5, fontWeight: FontWeight.w800),
                ),
              ),
              if (_loadingCounts || _loadingPage)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final k in _kinds)
                if (_hasKind(k) || k == 'body')
                  _choice(_kindLabel(k), _kind == k, () {
                    if (_kind == k) return;
                    _jumpToItem(kind: k);
                  }),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '이전 쪽',
                    visualDensity: VisualDensity.compact,
                    onPressed: _loadingPage || _page <= 1 ? null : () => unawaited(_loadPage(_page - 1)),
                    icon: const Icon(Icons.chevron_left_rounded, color: _kText, size: 20),
                  ),
                  SizedBox(
                    width: 56,
                    child: TextField(
                      controller: _pageCtrl,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        filled: true,
                        fillColor: _kFieldBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _kBorder),
                        ),
                      ),
                      onSubmitted: (v) {
                        final p = int.tryParse(v.trim());
                        if (p != null && p > 0) unawaited(_loadPage(p));
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: '다음 쪽',
                    visualDensity: VisualDensity.compact,
                    onPressed: _loadingPage || (_pageCounts[_kind] ?? 0) > 0 && _page >= (_pageCounts[_kind] ?? 0)
                        ? null
                        : () => unawaited(_loadPage(_page + 1)),
                    icon: const Icon(Icons.chevron_right_rounded, color: _kText, size: 20),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: _loadingCounts ? null : () => _jumpToItem(kind: _kind),
                style: TextButton.styleFrom(foregroundColor: _kAccent, visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.my_location_rounded, size: 15),
                label: const Text('이 문항 위치', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill(answerLabel, it.existingAnswer.trim().isEmpty ? _kError : _kBlue),
              _pill(solutionLabel, it.hasSolutionRef || it.solutionMarkedNone ? _kAccent : _kError),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _kBorder, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildViewer(),
            ),
          ),
          const SizedBox(height: 10),
          if (sel != null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _action('그림 정답으로 저장', Icons.image_outlined, _kBlue,
                    busy ? null : () => unawaited(_run(() => widget.onSaveAnswerImage(sel))),
                    filled: true),
                _action('정답 글자 입력', Icons.edit_outlined, _kBlue, busy ? null : () => unawaited(_promptAnswerText(sel))),
                _action('해설 위치로 저장', Icons.menu_book_outlined, _kAccent,
                    busy || sel.sourceKind == 'ans' ? null : () => unawaited(_run(() => widget.onSaveSolution(sel))),
                    filled: true),
                _action('선택 취소', Icons.close_rounded, _kTextSub, () => setState(() => _selection = null)),
              ],
            )
          else
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '정답이나 해설 영역을 드래그로 감싸면 저장 버튼이 나옵니다. 저장하면 이 문항만 AI 가 다시 확인합니다.',
                    style: TextStyle(color: _kTextSub, fontSize: 12, height: 1.35),
                  ),
                ),
                if (!it.solutionMarkedNone) ...[
                  const SizedBox(width: 8),
                  _action('해설 없음', Icons.block_rounded, _kWarn, busy ? null : () => unawaited(widget.onMarkNoSolution())),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildViewer() {
    if (_loadingCounts || (_loadingPage && _rendered == null)) {
      return const Center(child: CircularProgressIndicator(color: _kAccent));
    }
    final r = _rendered;
    if (r == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error ?? 'PDF 쪽을 불러오지 못했습니다.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kTextSub, fontSize: 13),
          ),
        ),
      );
    }
    final boxes = _boxesForPage();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: AspectRatio(
        aspectRatio: r.widthPx / math.max(1, r.heightPx),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: widget.busy
                  ? null
                  : (d) {
                      final n = _norm(d.localPosition, size);
                      setState(() {
                        _dragStart = n;
                        _dragNow = n;
                      });
                    },
              onPanUpdate: (d) {
                if (_dragStart == null) return;
                setState(() => _dragNow = _norm(d.localPosition, size));
              },
              onPanEnd: (_) {
                final a = _dragStart;
                final b = _dragNow;
                if (a != null && b != null) _commitDrag(a, b);
                setState(() {
                  _dragStart = null;
                  _dragNow = null;
                });
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(r.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(
                    painter: _BoxPainter(
                      boxes: boxes,
                      selection: _selection,
                      dragStart: _dragStart,
                      dragNow: _dragNow,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Box {
  const _Box(this.region1k, this.color, this.label);

  final List<int> region1k;
  final Color color;
  final String label;
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({required this.boxes, this.selection, this.dragStart, this.dragNow});

  final List<_Box> boxes;
  final List<int>? selection;
  final Offset? dragStart;
  final Offset? dragNow;

  Rect _rect(List<int> r, Size size) => Rect.fromLTRB(
        r[1] / 1000 * size.width,
        r[0] / 1000 * size.height,
        r[3] / 1000 * size.width,
        r[2] / 1000 * size.height,
      );

  void _label(Canvas canvas, Offset at, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800, background: Paint()..color = color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(at.dx, math.max(0, at.dy - tp.height)));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      if (b.region1k.length != 4) continue;
      final rect = _rect(b.region1k, size);
      canvas.drawRect(rect, Paint()..color = b.color.withValues(alpha: 0.10));
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = b.color,
      );
      _label(canvas, rect.topLeft, ' ${b.label} ', b.color);
    }
    Rect? sel;
    if (dragStart != null && dragNow != null) {
      sel = Rect.fromPoints(
        Offset(dragStart!.dx * size.width, dragStart!.dy * size.height),
        Offset(dragNow!.dx * size.width, dragNow!.dy * size.height),
      );
    } else if (selection != null && selection!.length == 4) {
      sel = _rect(selection!, size);
    }
    if (sel != null) {
      canvas.drawRect(sel, Paint()..color = _kWarn.withValues(alpha: 0.16));
      canvas.drawRect(
        sel,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _kWarn,
      );
      if (dragStart == null) _label(canvas, sel.topLeft, ' 고른 영역 ', _kWarn);
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) =>
      old.boxes != boxes || old.selection != selection || old.dragStart != dragStart || old.dragNow != dragNow;
}
