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
const Color _kAccent = Color(0xFF33A373);
const Color _kError = Color(0xFFE57373);

class TextbookPincetteDragResult {
  const TextbookPincetteDragResult({
    required this.rawPage,
    this.displayPage,
    required this.problemNumber,
    required this.subKey,
    required this.subIndex,
    required this.region1k,
  });

  final int rawPage;
  final int? displayPage;
  final String problemNumber;
  final String subKey;
  final int subIndex;
  final List<int> region1k;
}

/// PDF 페이지 위에서 마우스 드래그로 문항 영역([ymin, xmin, ymax, xmax] 0..1000)을 직접 지정하는 핀셋 추출 모달.
/// 빠진 문항을 새로 추가하거나, 영역이 잘못 잡힌 문항을 정확히 다시 지정할 때 사용한다.
Future<TextbookPincetteDragResult?> showTextbookPincetteDragDialog(
  BuildContext context, {
  required TextbookProblemReviewService service,
  required TextbookReviewUnitScope scope,
  required int initialRawPage,
  int? initialDisplayPage,
  required String initialProblemNumber,
  required String initialSubKey,
  int initialSubIndex = 0,
  List<int>? initialRegion1k,
  bool isNewMissingProblem = false,
}) {
  return showDialog<TextbookPincetteDragResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (_) => _TextbookPincetteDragDialog(
      service: service,
      scope: scope,
      initialRawPage: initialRawPage,
      initialDisplayPage: initialDisplayPage,
      initialProblemNumber: initialProblemNumber,
      initialSubKey: initialSubKey,
      initialSubIndex: initialSubIndex,
      initialRegion1k: initialRegion1k,
      isNewMissingProblem: isNewMissingProblem,
    ),
  );
}

class _TextbookPincetteDragDialog extends StatefulWidget {
  const _TextbookPincetteDragDialog({
    required this.service,
    required this.scope,
    required this.initialRawPage,
    this.initialDisplayPage,
    required this.initialProblemNumber,
    required this.initialSubKey,
    required this.initialSubIndex,
    this.initialRegion1k,
    required this.isNewMissingProblem,
  });

  final TextbookProblemReviewService service;
  final TextbookReviewUnitScope scope;
  final int initialRawPage;
  final int? initialDisplayPage;
  final String initialProblemNumber;
  final String initialSubKey;
  final int initialSubIndex;
  final List<int>? initialRegion1k;
  final bool isNewMissingProblem;

  @override
  State<_TextbookPincetteDragDialog> createState() => _TextbookPincetteDragDialogState();
}

class _TextbookPincetteDragDialogState extends State<_TextbookPincetteDragDialog> {
  late int _rawPage = math.max(1, widget.initialRawPage);
  late final TextEditingController _numCtrl = TextEditingController(text: widget.initialProblemNumber);
  late final TextEditingController _pageCtrl = TextEditingController(text: '${math.max(1, widget.initialRawPage)}');
  late String _subKey = widget.initialSubKey.trim().isEmpty ? 'A' : widget.initialSubKey.trim().toUpperCase();

  TextbookReviewRenderedRegion? _renderedPage;
  bool _loadingPage = true;
  String? _error;

  List<int>? _region1k;
  Offset? _dragStartNorm;
  Offset? _dragCurrentNorm;

  @override
  void initState() {
    super.initState();
    if (widget.initialRegion1k != null && widget.initialRegion1k!.length == 4) {
      _region1k = List<int>.from(widget.initialRegion1k!);
    }
    _loadPage(_rawPage);
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPage(int page) async {
    final target = math.max(1, page);
    setState(() {
      _rawPage = target;
      _pageCtrl.text = '$target';
      _loadingPage = true;
      _error = null;
    });
    try {
      final rendered = await widget.service.renderFullBodyPage(
        scope: widget.scope,
        rawPage: target,
        targetWidthPx: 1500,
      );
      if (!mounted) return;
      setState(() {
        _renderedPage = rendered;
        _loadingPage = false;
        if (rendered == null) {
          _error = '본문 PDF $target쪽을 렌더링하지 못했습니다.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPage = false;
        _error = 'PDF 페이지 로드 실패: $e';
      });
    }
  }

  Offset _clampNorm(Offset localPosition, Size size) {
    final dx = (localPosition.dx / math.max(1.0, size.width)).clamp(0.0, 1.0);
    final dy = (localPosition.dy / math.max(1.0, size.height)).clamp(0.0, 1.0);
    return Offset(dx, dy);
  }

  void _commitDragBox(Offset a, Offset b) {
    final xmin = (math.min(a.dx, b.dx) * 1000).round().clamp(0, 995);
    final xmax = (math.max(a.dx, b.dx) * 1000).round().clamp(xmin + 5, 1000);
    final ymin = (math.min(a.dy, b.dy) * 1000).round().clamp(0, 995);
    final ymax = (math.max(a.dy, b.dy) * 1000).round().clamp(ymin + 5, 1000);
    if (xmax - xmin < 15 || ymax - ymin < 15) return;
    setState(() {
      _region1k = [ymin, xmin, ymax, xmax];
    });
  }

  void _submit() {
    final numStr = _numCtrl.text.trim();
    if (numStr.isEmpty) {
      setState(() => _error = '문항 번호를 입력해 주세요.');
      return;
    }
    final box = _region1k;
    if (box == null || box.length != 4) {
      setState(() => _error = 'PDF 이미지 위에서 마우스를 드래그해 문항 영역을 지정해 주세요.');
      return;
    }
    Navigator.of(context).pop(
      TextbookPincetteDragResult(
        rawPage: _rawPage,
        displayPage: widget.initialDisplayPage,
        problemNumber: numStr,
        subKey: _subKey,
        subIndex: widget.initialSubIndex,
        region1k: box,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: _kPanelBg,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: _kBorder, width: 0.5),
      ),
      child: SizedBox(
        width: math.min(1120, size.width - 48),
        height: math.min(860, size.height - 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.crop_free_rounded, color: _kAccent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isNewMissingProblem
                              ? '핀셋 추출 — 빠진 문항 영역 직접 지정 (${widget.scope.bookTitle})'
                              : '핀셋 추출 — 본문 PDF 영역 직접 지정 (${widget.initialProblemNumber}번)',
                          style: const TextStyle(color: _kText, fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          '아래 PDF 페이지 위에서 문항 전체(본문·수식·표·그림 포함)를 마우스로 드래그해 감싸면 고정밀 AI가 본문·정답·해설을 즉시 추출합니다.',
                          style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: _kTextSub),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _kFieldBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _kBorder, width: 0.5),
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('PDF 쪽', style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: '이전 쪽',
                          visualDensity: VisualDensity.compact,
                          onPressed: _loadingPage || _rawPage <= 1 ? null : () => _loadPage(_rawPage - 1),
                          icon: const Icon(Icons.chevron_left_rounded, color: _kText),
                        ),
                        SizedBox(
                          width: 64,
                          child: TextField(
                            controller: _pageCtrl,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              filled: true,
                              fillColor: _kPanelBg,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: _kBorder),
                              ),
                            ),
                            onSubmitted: (v) {
                              final p = int.tryParse(v.trim());
                              if (p != null && p > 0) _loadPage(p);
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: '다음 쪽',
                          visualDensity: VisualDensity.compact,
                          onPressed: _loadingPage ? null : () => _loadPage(_rawPage + 1),
                          icon: const Icon(Icons.chevron_right_rounded, color: _kText),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('문항 번호', style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 96,
                          child: TextField(
                            controller: _numCtrl,
                            style: const TextStyle(color: _kText, fontSize: 13.5, fontWeight: FontWeight.w800),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '예: 03',
                              hintStyle: const TextStyle(color: _kTextSub, fontSize: 12),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              filled: true,
                              fillColor: _kPanelBg,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: _kBorder),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('슬롯', style: TextStyle(color: _kTextSub, fontSize: 12.5, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: const ['A', 'B', 'C', 'D', 'E'].contains(_subKey) ? _subKey : 'A',
                            dropdownColor: _kPanelBg,
                            style: const TextStyle(color: _kText, fontSize: 13, fontWeight: FontWeight.w800),
                            items: [
                              for (final k in const ['A', 'B', 'C', 'D', 'E'])
                                DropdownMenuItem(value: k, child: Text('슬롯 $k')),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _subKey = v);
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_region1k != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _kAccent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: _kAccent.withValues(alpha: 0.6)),
                        ),
                        child: Text(
                          '영역 [${_region1k!.join(', ')}]',
                          style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.w800),
                        ),
                      ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: _kError, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _kBorder, width: 0.5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _loadingPage
                      ? const Center(child: CircularProgressIndicator(color: _kAccent))
                      : _renderedPage == null
                          ? Center(
                              child: Text(
                                _error ?? 'PDF 페이지를 불러오지 못했습니다.',
                                style: const TextStyle(color: _kTextSub, fontSize: 13),
                              ),
                            )
                          : Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: AspectRatio(
                                  aspectRatio: _renderedPage!.widthPx / math.max(1, _renderedPage!.heightPx),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                                      return GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanStart: (d) {
                                          final norm = _clampNorm(d.localPosition, canvasSize);
                                          setState(() {
                                            _dragStartNorm = norm;
                                            _dragCurrentNorm = norm;
                                          });
                                        },
                                        onPanUpdate: (d) {
                                          if (_dragStartNorm == null) return;
                                          setState(() {
                                            _dragCurrentNorm = _clampNorm(d.localPosition, canvasSize);
                                          });
                                        },
                                        onPanEnd: (_) {
                                          if (_dragStartNorm != null && _dragCurrentNorm != null) {
                                            _commitDragBox(_dragStartNorm!, _dragCurrentNorm!);
                                          }
                                          setState(() {
                                            _dragStartNorm = null;
                                            _dragCurrentNorm = null;
                                          });
                                        },
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.memory(
                                              _renderedPage!.bytes,
                                              fit: BoxFit.fill,
                                            ),
                                            CustomPaint(
                                              painter: _PincetteBoxPainter(
                                                region1k: _region1k,
                                                dragStartNorm: _dragStartNorm,
                                                dragCurrentNorm: _dragCurrentNorm,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SizedBox(
                    height: 52,
                    width: 120,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kText,
                        side: const BorderSide(color: _kBorder),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('닫기', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _loadingPage ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                      label: const Text(
                        '이 영역으로 핀셋 추출 실행',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PincetteBoxPainter extends CustomPainter {
  const _PincetteBoxPainter({
    required this.region1k,
    required this.dragStartNorm,
    required this.dragCurrentNorm,
  });

  final List<int>? region1k;
  final Offset? dragStartNorm;
  final Offset? dragCurrentNorm;

  @override
  void paint(Canvas canvas, Size size) {
    Rect? rect;
    if (dragStartNorm != null && dragCurrentNorm != null) {
      rect = Rect.fromPoints(
        Offset(dragStartNorm!.dx * size.width, dragStartNorm!.dy * size.height),
        Offset(dragCurrentNorm!.dx * size.width, dragCurrentNorm!.dy * size.height),
      );
    } else if (region1k != null && region1k!.length == 4) {
      final ymin = region1k![0] / 1000.0 * size.height;
      final xmin = region1k![1] / 1000.0 * size.width;
      final ymax = region1k![2] / 1000.0 * size.height;
      final xmax = region1k![3] / 1000.0 * size.width;
      rect = Rect.fromLTRB(xmin, ymin, xmax, ymax);
    }
    if (rect == null) return;

    final fillPaint = Paint()
      ..color = _kAccent.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = _kAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    canvas.drawRect(rect, fillPaint);
    canvas.drawRect(rect, borderPaint);

    const handleRadius = 5.0;
    final handlePaint = Paint()..color = _kAccent;
    for (final corner in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      canvas.drawCircle(corner, handleRadius, handlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PincetteBoxPainter oldDelegate) =>
      oldDelegate.region1k != region1k ||
      oldDelegate.dragStartNorm != dragStartNorm ||
      oldDelegate.dragCurrentNorm != dragCurrentNorm;
}
