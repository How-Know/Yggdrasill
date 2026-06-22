import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'package:mneme_flutter/widgets/pdf/pdf_editor_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../services/data_manager.dart';

const Color _pdfPanelBg = Color(0xFF10171A);
const Color _pdfFieldBg = Color(0xFF15171C);
const Color _pdfBorder = Color(0xFF223131);
const Color _pdfText = Color(0xFFEAF2F2);
const Color _pdfTextSub = Color(0xFF9FB3B3);
const Color _pdfAccent = Color(0xFF33A373);

enum PdfEditPanelPresentation { sideSheet, bottomSheet }

class PdfEditPanel extends StatefulWidget {
  const PdfEditPanel({
    super.key,
    this.dialogContext,
    this.presentation = PdfEditPanelPresentation.sideSheet,
  });

  final BuildContext? dialogContext;
  final PdfEditPanelPresentation presentation;

  @override
  State<PdfEditPanel> createState() => _PdfEditPanelState();
}

class _PdfEditGradeOption {
  const _PdfEditGradeOption({required this.key, required this.label});

  final String key;
  final String label;
}

class _PdfEditPanelState extends State<PdfEditPanel> {
  static const List<String> _gradeOrder = [
    '초1',
    '초2',
    '초3',
    '초4',
    '초5',
    '초6',
    '중1',
    '중2',
    '중3',
    '고1',
    '고2',
    '고3',
    'N수',
  ];

  final TextEditingController _inputCtrl = ImeAwareTextEditingController();
  final TextEditingController _rangesCtrl = ImeAwareTextEditingController();
  final TextEditingController _fileNameCtrl = ImeAwareTextEditingController();

  List<_PdfEditGradeOption> _grades = const [];
  int _defaultGradeIndex = 0;
  String? _lastOutputPath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGrades());
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _rangesCtrl.dispose();
    _fileNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadGrades() async {
    try {
      final rows = await DataManager.instance.getResourceGrades();
      final names = <String>[];
      for (final row in rows) {
        final name = (row['name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty) names.add(name);
      }
      final next = _buildGradeOptionsFromNames(names);
      if (!mounted) return;
      setState(() {
        _grades = next;
        _defaultGradeIndex = _defaultGradeIndex.clamp(
          0,
          next.isEmpty ? 0 : next.length - 1,
        );
      });
    } catch (_) {}
  }

  List<_PdfEditGradeOption> _buildGradeOptionsFromNames(
    Iterable<String> names,
  ) {
    final unique =
        names.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toSet();
    if (unique.isEmpty) return const <_PdfEditGradeOption>[];

    final orderIndex = <String, int>{};
    for (int i = 0; i < _gradeOrder.length; i++) {
      orderIndex[_gradeOrder[i]] = i;
    }

    final known = <String>[];
    final unknown = <String>[];
    for (final name in unique) {
      if (orderIndex.containsKey(name)) {
        known.add(name);
      } else {
        unknown.add(name);
      }
    }
    known.sort((a, b) => orderIndex[a]!.compareTo(orderIndex[b]!));
    unknown.sort();
    return [...known, ...unknown]
        .map((name) => _PdfEditGradeOption(key: name, label: name))
        .toList();
  }

  String _currentGradeLabel() {
    if (_grades.isEmpty) return '';
    final idx = _defaultGradeIndex.clamp(0, _grades.length - 1);
    return _grades[idx].label;
  }

  String _basename(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'[\\/]+'));
    return parts.isEmpty ? trimmed : parts.last;
  }

  String _basenameWithoutExtension(String path) {
    final name = _basename(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }

  void _syncDefaultFileName({required String inputPath}) {
    final trimmed = inputPath.trim();
    if (trimmed.isEmpty) return;
    if (_fileNameCtrl.text.trim().isNotEmpty) return;
    final base = _basenameWithoutExtension(trimmed);
    final grade = _currentGradeLabel();
    _fileNameCtrl.text = grade.isEmpty ? '${base}_본문.pdf' : '${base}_${grade}_본문.pdf';
  }

  Future<void> _pickInput() async {
    const typeGroup = XTypeGroup(label: 'PDF', extensions: ['pdf']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    _inputCtrl.text = file.path;
    _syncDefaultFileName(inputPath: file.path);
    if (mounted) setState(() {});
  }

  List<int> _parseRanges(String input, int maxPages) {
    final pages = <int>{};
    for (final part in input.split(',')) {
      final token = part.trim();
      if (token.isEmpty) continue;
      if (token.contains('-')) {
        final split = token.split('-');
        if (split.length != 2) continue;
        final a = int.tryParse(split[0].trim());
        final b = int.tryParse(split[1].trim());
        if (a == null || b == null) continue;
        final start = a.clamp(1, maxPages);
        final end = b.clamp(1, maxPages);
        final lo = start <= end ? start : end;
        final hi = start <= end ? end : start;
        for (int i = lo; i <= hi; i++) {
          pages.add(i);
        }
      } else {
        final value = int.tryParse(token);
        if (value != null && value >= 1 && value <= maxPages) {
          pages.add(value);
        }
      }
    }
    return pages.toList()..sort();
  }

  Future<void> _generateFromRanges() async {
    if (_busy) return;
    final inputPath = _inputCtrl.text.trim();
    final ranges = _rangesCtrl.text.trim();
    var outputName = _fileNameCtrl.text.trim();

    if (inputPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')),
      );
      return;
    }
    if (!inputPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF 파일만 지원합니다.')),
      );
      return;
    }
    if (ranges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('페이지 범위를 입력하세요.')),
      );
      return;
    }

    if (outputName.isEmpty) {
      final base = _basenameWithoutExtension(inputPath);
      final grade = _currentGradeLabel();
      outputName = grade.isEmpty ? '${base}_본문.pdf' : '${base}_${grade}_본문.pdf';
    }

    setState(() => _busy = true);
    try {
      final saveLocation = await getSaveLocation(suggestedName: outputName);
      if (saveLocation == null) return;
      var outputPath = saveLocation.path;
      if (!outputPath.toLowerCase().endsWith('.pdf')) {
        outputPath = '$outputPath.pdf';
      }

      final inputBytes = await File(inputPath).readAsBytes();
      final source = sf.PdfDocument(inputBytes: inputBytes);
      final selected = _parseRanges(ranges, source.pages.count);
      if (selected.isEmpty) {
        source.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('유효한 페이지 범위가 없습니다.')),
          );
        }
        return;
      }

      final destination = sf.PdfDocument();
      try {
        destination.pageSettings.size = source.pageSettings.size;
        destination.pageSettings.orientation = source.pageSettings.orientation;
        destination.pageSettings.margins.all = 0;
      } catch (_) {}

      for (final pageNumber in selected) {
        if (pageNumber < 1 || pageNumber > source.pages.count) continue;
        final sourcePage = source.pages[pageNumber - 1];
        try {
          destination.pageSettings.size = sourcePage.size;
          destination.pageSettings.margins.all = 0;
        } catch (_) {}
        final template = sourcePage.createTemplate();
        final newPage = destination.pages.add();
        try {
          newPage.graphics.drawPdfTemplate(template, const Offset(0, 0));
        } catch (_) {}
      }

      final outBytes = await destination.save();
      source.dispose();
      destination.dispose();
      await File(outputPath).writeAsBytes(outBytes, flush: true);
      if (!mounted) return;
      setState(() => _lastOutputPath = outputPath);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF 생성이 완료되었습니다.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPreviewSelectDialog() async {
    final dialogContext = widget.dialogContext ?? context;
    final inputPath = _inputCtrl.text.trim();
    if (inputPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('원본 PDF를 먼저 선택하세요.')),
      );
      return;
    }
    if (!inputPath.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF 파일만 지원합니다.')),
      );
      return;
    }

    var outputName = _fileNameCtrl.text.trim();
    if (outputName.isEmpty) {
      final base = _basenameWithoutExtension(inputPath);
      final grade = _currentGradeLabel();
      outputName = grade.isEmpty ? '${base}_본문.pdf' : '${base}_${grade}_본문.pdf';
    }

    final outputPath = await showDialog<String>(
      context: dialogContext,
      useRootNavigator: true,
      builder: (_) => PdfPreviewSelectDialog(
        inputPath: inputPath,
        suggestedOutputName: outputName,
      ),
    );
    if (!mounted) return;
    if (outputPath != null && outputPath.trim().isNotEmpty) {
      setState(() => _lastOutputPath = outputPath.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final inputPath = _inputCtrl.text.trim();
    final hasPdf = inputPath.isNotEmpty && inputPath.toLowerCase().endsWith('.pdf');
    final hasRanges = _rangesCtrl.text.trim().isNotEmpty;
    final isBottomSheet =
        widget.presentation == PdfEditPanelPresentation.bottomSheet;

    return Padding(
      padding: EdgeInsets.fromLTRB(10, isBottomSheet ? 6 : 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isBottomSheet) ...[
            const Text(
              'PDF 편집',
              style: TextStyle(
                color: _pdfText,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _pdfPanelBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _pdfBorder),
            ),
            child: const Text(
              '범위 입력에서 페이지를 지정하거나, “미리보기로 편집”으로 검수/순서조정 후 PDF를 생성하세요.',
              style: TextStyle(
                color: _pdfTextSub,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '입력 PDF',
                    style: TextStyle(
                      color: _pdfTextSub,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _inputCtrl,
                    onChanged: (value) {
                      if (_busy) return;
                      setState(() {});
                      if (value.trim().toLowerCase().endsWith('.pdf')) {
                        _syncDefaultFileName(inputPath: value);
                      }
                    },
                    style: const TextStyle(
                      color: _pdfText,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: _inputDecoration('원본 PDF 경로'),
                  ),
                  const SizedBox(height: 10),
                  DropTarget(
                    onDragDone: (detail) {
                      if (_busy || detail.files.isEmpty) return;
                      final path = detail.files.first.path;
                      if (path.toLowerCase().endsWith('.pdf')) {
                        setState(() {
                          _inputCtrl.text = path;
                          _syncDefaultFileName(inputPath: path);
                        });
                      }
                    },
                    child: Container(
                      height: 67,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _pdfFieldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _pdfBorder),
                      ),
                      child: const Text(
                        '여기로 PDF를 드래그하여 선택',
                        style: TextStyle(
                          color: _pdfTextSub,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickInput,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('찾기'),
                    style: _outlinedStyle(),
                  ),
                  if (hasPdf) ...[
                    const SizedBox(height: 14),
                    const Text(
                      '페이지 범위 (예: 1-3,5,7-9)',
                      style: TextStyle(
                        color: _pdfTextSub,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _rangesCtrl,
                      onChanged: (_) {
                        if (_busy) return;
                        setState(() {});
                      },
                      style: const TextStyle(
                        color: _pdfText,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: _inputDecoration('쉼표로 구분, 범위는 하이픈'),
                    ),
                  ],
                  if (hasPdf && hasRanges) ...[
                    const SizedBox(height: 14),
                    const Text(
                      '파일명',
                      style: TextStyle(
                        color: _pdfTextSub,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _fileNameCtrl,
                      style: const TextStyle(
                        color: _pdfText,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: _inputDecoration('원본명_과정_본문.pdf'),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _generateFromRanges,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined, size: 16),
                        label: const Text('범위로 생성'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _pdfAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (_lastOutputPath != null &&
                      _lastOutputPath!.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _LastOutputCard(
                      path: _lastOutputPath!,
                      gradeLabel: _currentGradeLabel(),
                      basename: _basename(_lastOutputPath!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: hasPdf
                ? SizedBox(
                    key: const ValueKey('pdf_edit_preview_btn'),
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _openPreviewSelectDialog,
                      icon: const Icon(Icons.preview_outlined, size: 16),
                      label: const Text('미리보기로 편집'),
                      style: _outlinedStyle(),
                    ),
                  )
                : const SizedBox(
                    key: ValueKey('pdf_edit_preview_btn_empty'),
                    height: 48,
                  ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hintText) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: _pdfTextSub),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _pdfBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _pdfAccent, width: 1.4),
      ),
      filled: true,
      fillColor: _pdfFieldBg,
    );
  }

  ButtonStyle _outlinedStyle() {
    return OutlinedButton.styleFrom(
      foregroundColor: _pdfTextSub,
      side: const BorderSide(color: _pdfBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}

class _LastOutputCard extends StatelessWidget {
  const _LastOutputCard({
    required this.path,
    required this.gradeLabel,
    required this.basename,
  });

  final String path;
  final String gradeLabel;
  final String basename;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _pdfFieldBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _pdfBorder.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '마지막 생성',
            style: TextStyle(
              color: _pdfTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            basename,
            style: const TextStyle(
              color: _pdfText,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: () async {
                  try {
                    await OpenFilex.open(path);
                  } catch (_) {}
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: _pdfBorder.withValues(alpha: 0.9)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('열기'),
              ),
              const SizedBox(width: 8),
              Text(
                '과정: ${gradeLabel.isEmpty ? '-' : gradeLabel}',
                style: const TextStyle(
                  color: _pdfTextSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
