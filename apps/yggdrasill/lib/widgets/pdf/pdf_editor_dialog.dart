import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

// Dialog design language (shared with other dialogs like memo/student registration)
const Color _dlgBg = Color(0xFF0B1112);
const Color _dlgPanelBg = Color(0xFF10171A);
const Color _dlgFieldBg = Color(0xFF15171C);
const Color _dlgBorder = Color(0xFF223131);
const Color _dlgText = Color(0xFFEAF2F2);
const Color _dlgTextSub = Color(0xFF9FB3B3);
const Color _dlgAccent = Color(0xFF33A373);

class PdfEditorDialog extends StatefulWidget {
  final String? initialInputPath;
  final String grade;
  final String kindKey; // 'body' | 'ans' | 'sol'

  const PdfEditorDialog({
    super.key,
    this.initialInputPath,
    required this.grade,
    required this.kindKey,
  });

  @override
  State<PdfEditorDialog> createState() => _PdfEditorDialogState();
}

class _PdfEditorDialogState extends State<PdfEditorDialog> with SingleTickerProviderStateMixin {
  final TextEditingController _inputPath = ImeAwareTextEditingController();
  final TextEditingController _ranges = ImeAwareTextEditingController();
  final TextEditingController _fileName = ImeAwareTextEditingController();
  String? _outputPath;
  bool _busy = false;

  final List<int> _selectedPages = [];
  final Map<int, List<Rect>> _regionsByPage = {};
  Rect? _dragRect;
  Offset? _dragStart;
  final GlobalKey _previewKey = GlobalKey();
  int _currentPreviewPage = 1;
  PdfDocument? _previewDoc;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.initialInputPath != null && widget.initialInputPath!.isNotEmpty) {
      _inputPath.text = widget.initialInputPath!;
      final base = p.basenameWithoutExtension(widget.initialInputPath!);
      final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
      _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
    }
  }

  List<int> _parseRanges(String input, int maxPages) {
    final Set<int> pages = {};
    for (final part in input.split(',')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (t.contains('-')) {
        final sp = t.split('-');
        if (sp.length != 2) continue;
        final a = int.tryParse(sp[0].trim());
        final b = int.tryParse(sp[1].trim());
        if (a == null || b == null) continue;
        final start = a < 1 ? 1 : a;
        final end = b > maxPages ? maxPages : b;
        for (int i = start; i <= end; i++) pages.add(i);
      } else {
        final v = int.tryParse(t);
        if (v != null && v >= 1 && v <= maxPages) pages.add(v);
      }
    }
    final list = pages.toList()..sort();
    return list;
  }

  @override
  void dispose() {
    _inputPath.dispose();
    _ranges.dispose();
    _fileName.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isPreviewTab = _tabController.index == 1;
    final double dialogWidth = isPreviewTab ? 1520 : 760;
    final double dialogHeight = isPreviewTab ? 1248 : 624;

    InputDecoration decoration({String? hintText}) => InputDecoration(
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
            borderSide: const BorderSide(color: _dlgAccent, width: 1.4),
          ),
        );

    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: _dlgTextSub,
      side: const BorderSide(color: _dlgBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: _dlgPanelBg,
    );

    return AlertDialog(
      backgroundColor: _dlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _dlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        'PDF 편집기',
        style: TextStyle(color: _dlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: DefaultTabController(
          length: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: _dlgBorder, height: 1),
              const SizedBox(height: 14),
              Theme(
                data: Theme.of(context).copyWith(
                  tabBarTheme: const TabBarThemeData(
                    indicatorColor: _dlgAccent,
                    labelColor: _dlgText,
                    unselectedLabelColor: _dlgTextSub,
                  ),
                ),
                child: TabBar(
                  controller: _tabController,
                  tabs: const [
                    Tab(text: '범위 입력'),
                    Tab(text: '미리보기 선택'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: <Widget>[
                    // Tab 1: 텍스트 범위 입력
                    SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('입력 PDF', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _inputPath,
                              style: const TextStyle(color: _dlgText, fontWeight: FontWeight.w700),
                              decoration: decoration(hintText: '원본 PDF 경로'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 36,
                            width: 1.2 * 200,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final typeGroup = XTypeGroup(label: 'pdf', extensions: ['pdf']);
                                final f = await openFile(acceptedTypeGroups: [typeGroup]);
                                if (f != null) {
                                  setState(() {
                                    _inputPath.text = f.path;
                                    final base = p.basenameWithoutExtension(f.path);
                                    final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
                                    _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
                                  });
                                }
                              },
                              icon: const Icon(Icons.folder_open, size: 16),
                              label: const Text('찾기'),
                              style: outlinedBtnStyle,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        // 드래그 박스: 여기에 PDF 파일을 드래그하여 선택
                        DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first;
                            final path = xf.path;
                            if (path != null && path.toLowerCase().endsWith('.pdf')) {
                              setState(() {
                                _inputPath.text = path;
                                final base = p.basenameWithoutExtension(path);
                                final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
                                _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
                              });
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            height: 120,
                            alignment: Alignment.center,
                            margin: const EdgeInsets.only(top: 4),
                            decoration: BoxDecoration(
                              color: _dlgFieldBg,
                              border: Border.all(color: _dlgBorder, width: 1.2, style: BorderStyle.solid),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.picture_as_pdf, color: _dlgTextSub, size: 28),
                                SizedBox(height: 8),
                                Text('여기로 PDF를 드래그하여 선택', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('페이지 범위 (예: 1-3,5,7-9)', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _ranges,
                          style: const TextStyle(color: _dlgText, fontWeight: FontWeight.w700),
                          decoration: decoration(hintText: '쉼표로 구분, 범위는 하이픈'),
                        ),
                        const SizedBox(height: 12),
                        const Text('파일명', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _fileName,
                          style: const TextStyle(color: _dlgText, fontWeight: FontWeight.w700),
                          decoration: decoration(hintText: '원본명_과정_종류.pdf'),
                        ),
                      ]),
                    ),
                    // Tab 2: 미리보기 선택 (썸네일 + 본문 + 영역 드래그)
                    Column(
                      children: [
                        Expanded(
                          child: _inputPath.text.trim().isEmpty
                              ? const Center(child: Text('PDF를 먼저 선택하세요', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700)))
                              : FutureBuilder<PdfDocument>(
                                  future: PdfDocument.openFile(_inputPath.text.trim()),
                                  builder: (context, snapshot) {
                                    if (snapshot.hasError) {
                                      return Center(
                                        child: Text(
                                          '열기 오류: ${snapshot.error}',
                                          style: const TextStyle(color: Colors.redAccent),
                                        ),
                                      );
                                    }
                                    if (!snapshot.hasData) {
                                      return const Center(child: CircularProgressIndicator());
                                    }
                                    final doc = snapshot.data!;
                                    final pageCount = doc.pages.length;
                                    _previewDoc = doc;
                                    _currentPreviewPage = _currentPreviewPage.clamp(1, pageCount).toInt();
                                    return Row(
                                      children: [
                                        SizedBox(
                                          width: 160,
                                          child: ListView.builder(
                                            itemCount: pageCount,
                                            itemBuilder: (c, i) {
                                              final pageNum = i + 1;
                                              final isCurrent = pageNum == _currentPreviewPage;
                                              final isSelected = _selectedPages.contains(pageNum);
                                              return Padding(
                                                padding: const EdgeInsets.all(6.0),
                                                child: Stack(
                                                  children: [
                                                    InkWell(
                                                      onTap: () => setState(() {
                                                        _currentPreviewPage = pageNum;
                                                      }),
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: AspectRatio(
                                                        aspectRatio: 1 / 1.4,
                                                        child: AnimatedContainer(
                                                          duration: const Duration(milliseconds: 140),
                                                          decoration: BoxDecoration(
                                                            color: isCurrent ? _dlgAccent.withOpacity(0.08) : Colors.transparent,
                                                            border: Border.all(
                                                              color: isCurrent ? _dlgAccent : _dlgBorder,
                                                              width: isCurrent ? 2 : 1,
                                                            ),
                                                            borderRadius: BorderRadius.circular(6),
                                                            boxShadow: isCurrent
                                                                ? [
                                                                    BoxShadow(
                                                                      color: _dlgAccent.withOpacity(0.18),
                                                                      blurRadius: 10,
                                                                      offset: const Offset(0, 4),
                                                                    ),
                                                                  ]
                                                                : null,
                                                          ),
                                                          child: ClipRRect(
                                                            borderRadius: BorderRadius.circular(5),
                                                            clipBehavior: Clip.hardEdge,
                                                            child: PdfPageView(document: doc, pageNumber: pageNum),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    Positioned(
                                                      right: 6,
                                                      top: 6,
                                                      child: Tooltip(
                                                        message: isSelected ? '이미 선택됨' : '페이지 추가',
                                                        child: InkWell(
                                                          onTap: isSelected
                                                              ? null
                                                              : () {
                                                                  setState(() {
                                                                    _currentPreviewPage = pageNum;
                                                                    _selectedPages.add(pageNum);
                                                                  });
                                                                },
                                                          borderRadius: BorderRadius.circular(999),
                                                          child: Container(
                                                            width: 26,
                                                            height: 26,
                                                            decoration: BoxDecoration(
                                                              color: isSelected ? Colors.black54 : _dlgAccent,
                                                              shape: BoxShape.circle,
                                                              border: Border.all(color: Colors.white24),
                                                            ),
                                                            child: Icon(
                                                              isSelected ? Icons.check : Icons.add,
                                                              size: 16,
                                                              color: Colors.white,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: LayoutBuilder(
                                            builder: (ctx, constraints) {
                                              final showPage = _currentPreviewPage;
                                              final regions = _regionsByPage[showPage] ?? [];
                                              return Column(
                                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                                children: [
                                                  Padding(
                                                    padding: const EdgeInsets.only(bottom: 6),
                                                    child: Row(
                                                      children: [
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                          decoration: BoxDecoration(
                                                            color: _dlgPanelBg,
                                                            borderRadius: BorderRadius.circular(999),
                                                            border: Border.all(color: _dlgBorder),
                                                          ),
                                                          child: Text(
                                                            '$showPage / $pageCount',
                                                            style: const TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Listener(
                                                      onPointerSignal: (signal) {
                                                        if (signal is PointerScrollEvent) {
                                                          final dy = signal.scrollDelta.dy;
                                                          if (dy != 0) {
                                                            setState(() {
                                                              _currentPreviewPage =
                                                                  (_currentPreviewPage + (dy > 0 ? 1 : -1)).clamp(1, pageCount);
                                                            });
                                                          }
                                                        }
                                                      },
                                                      child: GestureDetector(
                                                        onPanStart: (d) {
                                                          setState(() {
                                                            _dragStart = d.localPosition;
                                                            _dragRect = Rect.fromLTWH(_dragStart!.dx, _dragStart!.dy, 0, 0);
                                                          });
                                                        },
                                                        onPanUpdate: (d) {
                                                          if (_dragStart == null) return;
                                                          setState(() {
                                                            _dragRect = Rect.fromPoints(_dragStart!, d.localPosition);
                                                          });
                                                        },
                                                        onPanEnd: (_) {
                                                          final Size size = constraints.biggest;
                                                          if (_dragRect != null) {
                                                            final r = _dragRect!;
                                                            final norm = Rect.fromLTWH(
                                                              (r.left / size.width).clamp(0.0, 1.0),
                                                              (r.top / size.height).clamp(0.0, 1.0),
                                                              (r.width / size.width).abs().clamp(0.0, 1.0),
                                                              (r.height / size.height).abs().clamp(0.0, 1.0),
                                                            );
                                                            setState(() {
                                                              final list = List<Rect>.from(_regionsByPage[showPage] ?? []);
                                                              list.add(norm);
                                                              _regionsByPage[showPage] = list;
                                                              _dragRect = null;
                                                              _dragStart = null;
                                                            });
                                                          } else {
                                                            setState(() {
                                                              _dragRect = null;
                                                              _dragStart = null;
                                                            });
                                                          }
                                                        },
                                                        child: Stack(
                                                          key: _previewKey,
                                                          children: [
                                                            Container(
                                                              decoration: BoxDecoration(border: Border.all(color: _dlgBorder)),
                                                              child: PdfPageView(
                                                                key: ValueKey('preview_$showPage'),
                                                                document: doc,
                                                                pageNumber: showPage,
                                                              ),
                                                            ),
                                                            Positioned.fill(
                                                              child: Builder(
                                                                builder: (context) {
                                                                  final Size size = constraints.biggest;
                                                                  return Stack(
                                                                    children: [
                                                                      for (final nr in regions)
                                                                        Positioned(
                                                                          left: nr.left * size.width,
                                                                          top: nr.top * size.height,
                                                                          width: nr.width * size.width,
                                                                          height: nr.height * size.height,
                                                                          child: Container(
                                                                            decoration: BoxDecoration(
                                                                              color: _dlgAccent.withOpacity(0.14),
                                                                              border: Border.all(color: _dlgAccent),
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      if (_dragRect != null)
                                                                        Positioned(
                                                                          left: _dragRect!.left,
                                                                          top: _dragRect!.top,
                                                                          width: _dragRect!.width,
                                                                          height: _dragRect!.height,
                                                                          child: Container(
                                                                            decoration: BoxDecoration(
                                                                              color: Colors.white.withOpacity(0.06),
                                                                              border: Border.all(color: _dlgTextSub.withOpacity(0.7)),
                                                                            ),
                                                                          ),
                                                                        ),
                                                                    ],
                                                                  );
                                                                },
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 160,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              const Text(
                                                '선택 페이지',
                                                style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800),
                                              ),
                                              const SizedBox(height: 10),
                                              Expanded(
                                                child: ReorderableListView(
                                                  buildDefaultDragHandles: false,
                                                  proxyDecorator: (child, index, animation) {
                                                    return Material(
                                                      type: MaterialType.transparency,
                                                      child: _SelectedPageThumb(
                                                        document: _previewDoc,
                                                        pageNumber: _selectedPages[index],
                                                        height: 120,
                                                        outerRadius: 12,
                                                        innerRadius: 8,
                                                        showNumberBadge: true,
                                                      ),
                                                    );
                                                  },
                                                  children: [
                                                    for (int i = 0; i < _selectedPages.length; i++)
                                                      ReorderableDelayedDragStartListener(
                                                        key: ValueKey('sel_v_$i'),
                                                        index: i,
                                                        child: Container(
                                                          margin: const EdgeInsets.only(bottom: 8),
                                                          padding: const EdgeInsets.all(8),
                                                          decoration: BoxDecoration(
                                                            color: _dlgPanelBg,
                                                            borderRadius: BorderRadius.circular(12),
                                                            border: Border.all(color: _dlgBorder),
                                                          ),
                                                          child: Row(
                                                            children: [
                                                              Expanded(
                                                                child: SizedBox(
                                                                  height: 120,
                                                                  child: _SelectedPageThumb(
                                                                    document: _previewDoc,
                                                                    pageNumber: _selectedPages[i],
                                                                    height: 120,
                                                                    outerRadius: 8,
                                                                    innerRadius: 8,
                                                                    showNumberBadge: true,
                                                                    numberText: '${_selectedPages[i]}',
                                                                  ),
                                                                ),
                                                              ),
                                                              const SizedBox(width: 6),
                                                              InkWell(
                                                                onTap: () => setState(() {
                                                                  _selectedPages.removeAt(i);
                                                                }),
                                                                child: const Icon(Icons.close, size: 16, color: _dlgTextSub),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                  onReorder: (oldIndex, newIndex) {
                                                    setState(() {
                                                      if (newIndex > oldIndex) newIndex -= 1;
                                                      final v = _selectedPages.removeAt(oldIndex);
                                                      _selectedPages.insert(newIndex, v);
                                                    });
                                                  },
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          Text('선택: ${_selectedPages.join(', ')}', style: const TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 12),
                          if (_previewDoc != null)
                            Text(
                              '페이지: $_currentPreviewPage/${_previewDoc!.pages.length}',
                              style: const TextStyle(color: _dlgTextSub),
                            ),
                        ]),
                      ],
                    ),
                  ],
                ),
              ),
              if (_outputPath != null) Text('저장 경로: $_outputPath', style: const TextStyle(color: _dlgTextSub)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: _dlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  final inPath = _inputPath.text.trim();
                  final ranges = _ranges.text.trim();
                  var outName = _fileName.text.trim();
                  if (inPath.isEmpty) return;
                  if (ranges.isEmpty && _selectedPages.isEmpty) return;
                  if (outName.isEmpty) {
                    final base = p.basenameWithoutExtension(inPath);
                    final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
                    outName = '${base}_${widget.grade}_$suffix.pdf';
                  }
                  setState(() => _busy = true);
                  try {
                    // 1) 사용자 정의 경로 선택 (파일 저장 대화상자)
                    final saveLoc = await getSaveLocation(suggestedName: outName);
                    if (saveLoc == null) {
                      if (mounted) setState(() => _busy = false);
                      return;
                    }
                    var outPath = saveLoc.path;
                    if (!outPath.toLowerCase().endsWith('.pdf')) {
                      outPath = outPath + '.pdf';
                    }

                    // 2) Syncfusion로 inPath에서 선택 페이지를 "선택 순서대로" 새 문서에 복사 저장 (벡터 보존)
                    final inputBytes = await File(inPath).readAsBytes();
                    final src = sf.PdfDocument(inputBytes: inputBytes);
                    final selected =
                        _selectedPages.isNotEmpty ? List<int>.from(_selectedPages) : _parseRanges(ranges, src.pages.count);

                    final dst = sf.PdfDocument();
                    // 원본 기본 페이지 설정을 가능하면 유지
                    try {
                      dst.pageSettings.size = src.pageSettings.size;
                      dst.pageSettings.orientation = src.pageSettings.orientation;
                      dst.pageSettings.margins.all = 0;
                    } catch (_) {}

                    for (final pageNum in selected) {
                      if (pageNum < 1 || pageNum > src.pages.count) continue;
                      final srcPage = src.pages[pageNum - 1];
                      // ✅ 페이지별 실제 크기를 유지 (원본과 동일한 페이지 크기/여백 방지)
                      try {
                        final sz = srcPage.size;
                        dst.pageSettings.size = sz;
                        dst.pageSettings.margins.all = 0;
                      } catch (_) {}
                      final tmpl = srcPage.createTemplate();
                      final newPage = dst.pages.add();
                      // 템플릿을 좌상단(0,0)에 그려 원본 페이지 내용을 복사
                      try {
                        newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
                      } catch (_) {
                        // draw 실패 시에도 페이지는 유지
                      }
                    }

                    final outBytes = await dst.save();
                    src.dispose();
                    dst.dispose();
                    await File(outPath).writeAsBytes(outBytes, flush: true);
                    setState(() => _outputPath = outPath);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('PDF 생성이 완료되었습니다.')));
                      Navigator.pop(context, outPath);
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          style: FilledButton.styleFrom(
            backgroundColor: _dlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('생성', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}

/// 미리보기(썸네일/페이지 선택) 전용 다이얼로그.
/// - 오른쪽 슬라이드 시트에서 "미리보기 선택" 버튼으로만 진입시키기 위해 별도 분리
/// - 반환값: 생성된 PDF 경로(String) 또는 null
class PdfPreviewSelectDialog extends StatefulWidget {
  final String inputPath;
  /// `getSaveLocation(suggestedName: ...)`에 전달할 제안 파일명
  final String suggestedOutputName;

  const PdfPreviewSelectDialog({
    super.key,
    required this.inputPath,
    required this.suggestedOutputName,
  });

  @override
  State<PdfPreviewSelectDialog> createState() => _PdfPreviewSelectDialogState();
}

class _PdfPreviewSelectDialogState extends State<PdfPreviewSelectDialog> {
  bool _busy = false;
  String? _outputPath;

  final List<int> _selectedPages = [];
  final Map<int, List<Rect>> _regionsByPage = {};
  Rect? _dragRect;
  Offset? _dragStart;
  final GlobalKey _previewKey = GlobalKey();
  int _currentPreviewPage = 1;
  PdfDocument? _previewDoc;

  @override
  Widget build(BuildContext context) {
    final inPath = widget.inputPath.trim();
    final outSuggestion = widget.suggestedOutputName.trim().isNotEmpty
        ? widget.suggestedOutputName.trim()
        : '${p.basenameWithoutExtension(inPath)}.pdf';

    final outlinedBtnStyle = OutlinedButton.styleFrom(
      foregroundColor: _dlgTextSub,
      side: const BorderSide(color: _dlgBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: _dlgPanelBg,
    );

    return AlertDialog(
      backgroundColor: _dlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _dlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '미리보기 선택',
        style: TextStyle(color: _dlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 1520,
        height: 1248,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(color: _dlgBorder, height: 1),
            const SizedBox(height: 14),
            Expanded(
              child: inPath.isEmpty
                  ? const Center(
                      child: Text('PDF를 먼저 선택하세요', style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700)),
                    )
                  : FutureBuilder<PdfDocument>(
                      future: PdfDocument.openFile(inPath),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: Text('열기 오류: ${snapshot.error}', style: const TextStyle(color: Colors.redAccent)),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        final doc = snapshot.data!;
                        final pageCount = doc.pages.length;
                        _previewDoc = doc;
                        _currentPreviewPage = _currentPreviewPage.clamp(1, pageCount).toInt();

                        return Row(
                          children: [
                            SizedBox(
                              width: 160,
                              child: ListView.builder(
                                itemCount: pageCount,
                                itemBuilder: (c, i) {
                                  final pageNum = i + 1;
                                  final isCurrent = pageNum == _currentPreviewPage;
                                  final isSelected = _selectedPages.contains(pageNum);
                                  return Padding(
                                    padding: const EdgeInsets.all(6.0),
                                    child: Stack(
                                      children: [
                                        InkWell(
                                          onTap: () => setState(() {
                                            _currentPreviewPage = pageNum;
                                          }),
                                          borderRadius: BorderRadius.circular(6),
                                          child: AspectRatio(
                                            aspectRatio: 1 / 1.4,
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 140),
                                              decoration: BoxDecoration(
                                                color: isCurrent ? _dlgAccent.withOpacity(0.08) : Colors.transparent,
                                                border: Border.all(
                                                  color: isCurrent ? _dlgAccent : _dlgBorder,
                                                  width: isCurrent ? 2 : 1,
                                                ),
                                                borderRadius: BorderRadius.circular(6),
                                                boxShadow: isCurrent
                                                    ? [
                                                        BoxShadow(
                                                          color: _dlgAccent.withOpacity(0.18),
                                                          blurRadius: 10,
                                                          offset: const Offset(0, 4),
                                                        ),
                                                      ]
                                                    : null,
                                              ),
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(5),
                                                clipBehavior: Clip.hardEdge,
                                                child: PdfPageView(document: doc, pageNumber: pageNum),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          right: 6,
                                          top: 6,
                                          child: Tooltip(
                                            message: isSelected ? '이미 선택됨' : '페이지 추가',
                                            child: InkWell(
                                              onTap: (_busy || isSelected)
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        _currentPreviewPage = pageNum;
                                                        _selectedPages.add(pageNum);
                                                      });
                                                    },
                                              borderRadius: BorderRadius.circular(999),
                                              child: Container(
                                                width: 26,
                                                height: 26,
                                                decoration: BoxDecoration(
                                                  color: isSelected ? Colors.black54 : _dlgAccent,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(color: Colors.white24),
                                                ),
                                                child: Icon(
                                                  isSelected ? Icons.check : Icons.add,
                                                  size: 16,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (ctx, constraints) {
                                  final showPage = _currentPreviewPage;
                                  final regions = _regionsByPage[showPage] ?? [];
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: _dlgPanelBg,
                                                borderRadius: BorderRadius.circular(999),
                                                border: Border.all(color: _dlgBorder),
                                              ),
                                              child: Text(
                                                '$showPage / $pageCount',
                                                style: const TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                p.basename(inPath),
                                                style: const TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: Listener(
                                          onPointerSignal: (signal) {
                                            if (signal is PointerScrollEvent) {
                                              final dy = signal.scrollDelta.dy;
                                              if (dy != 0) {
                                                setState(() {
                                                  _currentPreviewPage = (_currentPreviewPage + (dy > 0 ? 1 : -1)).clamp(1, pageCount);
                                                });
                                              }
                                            }
                                          },
                                          child: GestureDetector(
                                            onPanStart: (d) {
                                              setState(() {
                                                _dragStart = d.localPosition;
                                                _dragRect = Rect.fromLTWH(_dragStart!.dx, _dragStart!.dy, 0, 0);
                                              });
                                            },
                                            onPanUpdate: (d) {
                                              if (_dragStart == null) return;
                                              setState(() {
                                                _dragRect = Rect.fromPoints(_dragStart!, d.localPosition);
                                              });
                                            },
                                            onPanEnd: (_) {
                                              final Size size = constraints.biggest;
                                              if (_dragRect != null) {
                                                final r = _dragRect!;
                                                final norm = Rect.fromLTWH(
                                                  (r.left / size.width).clamp(0.0, 1.0),
                                                  (r.top / size.height).clamp(0.0, 1.0),
                                                  (r.width / size.width).abs().clamp(0.0, 1.0),
                                                  (r.height / size.height).abs().clamp(0.0, 1.0),
                                                );
                                                setState(() {
                                                  final list = List<Rect>.from(_regionsByPage[showPage] ?? []);
                                                  list.add(norm);
                                                  _regionsByPage[showPage] = list;
                                                  _dragRect = null;
                                                  _dragStart = null;
                                                });
                                              } else {
                                                setState(() {
                                                  _dragRect = null;
                                                  _dragStart = null;
                                                });
                                              }
                                            },
                                            child: Stack(
                                              key: _previewKey,
                                              children: [
                                                Container(
                                                  decoration: BoxDecoration(border: Border.all(color: _dlgBorder)),
                                                  child: PdfPageView(
                                                    key: ValueKey('preview_$showPage'),
                                                    document: doc,
                                                    pageNumber: showPage,
                                                  ),
                                                ),
                                                Positioned.fill(
                                                  child: Builder(
                                                    builder: (context) {
                                                      final Size size = constraints.biggest;
                                                      return Stack(
                                                        children: [
                                                          for (final nr in regions)
                                                            Positioned(
                                                              left: nr.left * size.width,
                                                              top: nr.top * size.height,
                                                              width: nr.width * size.width,
                                                              height: nr.height * size.height,
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color: _dlgAccent.withOpacity(0.14),
                                                                  border: Border.all(color: _dlgAccent),
                                                                ),
                                                              ),
                                                            ),
                                                          if (_dragRect != null)
                                                            Positioned(
                                                              left: _dragRect!.left,
                                                              top: _dragRect!.top,
                                                              width: _dragRect!.width,
                                                              height: _dragRect!.height,
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color: Colors.white.withOpacity(0.06),
                                                                  border: Border.all(color: _dlgTextSub.withOpacity(0.7)),
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 160,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    '선택 페이지',
                                    style: TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: ReorderableListView(
                                      buildDefaultDragHandles: false,
                                      proxyDecorator: (child, index, animation) {
                                        return Material(
                                          type: MaterialType.transparency,
                                          child: _SelectedPageThumb(
                                            document: _previewDoc,
                                            pageNumber: _selectedPages[index],
                                            height: 120,
                                            outerRadius: 12,
                                            innerRadius: 8,
                                            showNumberBadge: true,
                                          ),
                                        );
                                      },
                                      children: [
                                        for (int i = 0; i < _selectedPages.length; i++)
                                          ReorderableDelayedDragStartListener(
                                            key: ValueKey('sel_v_$i'),
                                            index: i,
                                            child: Container(
                                              margin: const EdgeInsets.only(bottom: 8),
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: _dlgPanelBg,
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(color: _dlgBorder),
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: SizedBox(
                                                      height: 120,
                                                      child: _SelectedPageThumb(
                                                        document: _previewDoc,
                                                        pageNumber: _selectedPages[i],
                                                        height: 120,
                                                        outerRadius: 8,
                                                        innerRadius: 8,
                                                        showNumberBadge: true,
                                                        numberText: '${_selectedPages[i]}',
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  InkWell(
                                                    onTap: _busy
                                                        ? null
                                                        : () => setState(() {
                                                              _selectedPages.removeAt(i);
                                                            }),
                                                    child: const Icon(Icons.close, size: 16, color: _dlgTextSub),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                      onReorder: (oldIndex, newIndex) {
                                        setState(() {
                                          if (newIndex > oldIndex) newIndex -= 1;
                                          final v = _selectedPages.removeAt(oldIndex);
                                          _selectedPages.insert(newIndex, v);
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedPages.isEmpty ? '선택: 없음' : '선택: ${_selectedPages.join(', ')}',
                    style: const TextStyle(color: _dlgTextSub, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_outputPath != null && _outputPath!.trim().isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Text('저장: ${p.basename(_outputPath!)}', style: const TextStyle(color: _dlgTextSub)),
                ],
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: _dlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: (_busy || inPath.isEmpty)
              ? null
              : () async {
                  if (_selectedPages.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('선택된 페이지가 없습니다.')),
                    );
                    return;
                  }
                  setState(() => _busy = true);
                  try {
                    // 1) 사용자 정의 경로 선택 (파일 저장 대화상자)
                    final saveLoc = await getSaveLocation(suggestedName: outSuggestion);
                    if (saveLoc == null) {
                      if (mounted) setState(() => _busy = false);
                      return;
                    }
                    var outPath = saveLoc.path;
                    if (!outPath.toLowerCase().endsWith('.pdf')) {
                      outPath = '$outPath.pdf';
                    }

                    // 2) Syncfusion로 선택 페이지를 "선택 순서대로" 새 문서에 복사 저장 (벡터 보존)
                    final inputBytes = await File(inPath).readAsBytes();
                    final src = sf.PdfDocument(inputBytes: inputBytes);
                    final dst = sf.PdfDocument();
                    try {
                      dst.pageSettings.size = src.pageSettings.size;
                      dst.pageSettings.orientation = src.pageSettings.orientation;
                      dst.pageSettings.margins.all = 0;
                    } catch (_) {}

                    for (final pageNum in _selectedPages) {
                      if (pageNum < 1 || pageNum > src.pages.count) continue;
                      final srcPage = src.pages[pageNum - 1];
                      // ✅ 페이지별 실제 크기를 유지 (원본과 동일한 페이지 크기/여백 방지)
                      try {
                        final sz = srcPage.size;
                        dst.pageSettings.size = sz;
                        dst.pageSettings.margins.all = 0;
                      } catch (_) {}
                      final tmpl = srcPage.createTemplate();
                      final newPage = dst.pages.add();
                      try {
                        newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
                      } catch (_) {}
                    }

                    final outBytes = await dst.save();
                    src.dispose();
                    dst.dispose();
                    await File(outPath).writeAsBytes(outBytes, flush: true);
                    setState(() => _outputPath = outPath);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('PDF 생성이 완료되었습니다.')));
                      Navigator.pop(context, outPath);
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          style: FilledButton.styleFrom(
            backgroundColor: _dlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('생성', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}

class _SelectedPageThumb extends StatelessWidget {
  final PdfDocument? document;
  final int pageNumber;
  final double? width;
  final double? height;
  final double outerRadius;
  final double innerRadius;
  final bool showNumberBadge;
  final String? numberText;

  const _SelectedPageThumb({
    super.key,
    required this.document,
    required this.pageNumber,
    this.width,
    this.height,
    this.outerRadius = 12,
    this.innerRadius = 8,
    this.showNumberBadge = false,
    this.numberText,
  });

  @override
  Widget build(BuildContext context) {
    final pdf = document;
    final child = pdf == null
        ? const SizedBox()
        : ClipRRect(
            borderRadius: BorderRadius.circular(innerRadius),
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                Positioned.fill(child: PdfPageView(document: pdf, pageNumber: pageNumber)),
                if (showNumberBadge)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        numberText ?? '$pageNumber',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          );
    final a4 = AspectRatio(aspectRatio: 1 / 1.4, child: child);
    final sized = width != null
        ? SizedBox(width: width, child: a4)
        : height != null
            ? SizedBox(height: height, child: a4)
            : a4;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _dlgPanelBg,
        borderRadius: BorderRadius.circular(outerRadius),
        border: Border.all(color: _dlgBorder),
      ),
      child: sized,
    );
  }
}


