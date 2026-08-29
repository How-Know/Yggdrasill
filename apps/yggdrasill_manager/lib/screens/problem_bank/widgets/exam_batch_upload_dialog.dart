import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

const int maxExamBatchDocuments = 10;

class ExamBatchUploadPair {
  const ExamBatchUploadPair({
    required this.baseName,
    required this.hwpxPath,
    required this.pdfPath,
  });

  final String baseName;
  final String hwpxPath;
  final String pdfPath;
}

Future<List<ExamBatchUploadPair>?> showExamBatchUploadDialog(
  BuildContext context,
) {
  return showDialog<List<ExamBatchUploadPair>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _ExamBatchUploadDialog(),
  );
}

class _ExamBatchUploadDialog extends StatefulWidget {
  const _ExamBatchUploadDialog();

  @override
  State<_ExamBatchUploadDialog> createState() => _ExamBatchUploadDialogState();
}

class _ExamBatchUploadDialogState extends State<_ExamBatchUploadDialog> {
  static const Color _bg = Color(0xFF171717);
  static const Color _panel = Color(0xFF202020);
  static const Color _field = Color(0xFF292929);
  static const Color _border = Color(0xFF3A3A3A);
  static const Color _text = Color(0xFFF3F3F3);
  static const Color _textSub = Color(0xFF9EAAAA);
  static const Color _accent = Color(0xFF2C8C66);

  final Map<String, String> _hwpxByKey = <String, String>{};
  final Map<String, String> _pdfByKey = <String, String>{};
  bool _hwpxHover = false;
  bool _pdfHover = false;
  String _message = '';

  String _pairKey(String path) {
    final stem = p.basenameWithoutExtension(path).trim().toLowerCase();
    return stem.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _displayBaseName(String path) =>
      p.basenameWithoutExtension(path).trim();

  List<ExamBatchUploadPair> get _pairs {
    final keys = _hwpxByKey.keys
        .where(_pdfByKey.containsKey)
        .toList(growable: false)
      ..sort();
    return [
      for (final key in keys)
        ExamBatchUploadPair(
          baseName: _displayBaseName(_hwpxByKey[key]!),
          hwpxPath: _hwpxByKey[key]!,
          pdfPath: _pdfByKey[key]!,
        ),
    ];
  }

  List<String> get _unmatchedHwpx {
    final keys = _hwpxByKey.keys
        .where((key) => !_pdfByKey.containsKey(key))
        .toList()
      ..sort();
    return [for (final key in keys) p.basename(_hwpxByKey[key]!)];
  }

  List<String> get _unmatchedPdf {
    final keys = _pdfByKey.keys
        .where((key) => !_hwpxByKey.containsKey(key))
        .toList()
      ..sort();
    return [for (final key in keys) p.basename(_pdfByKey[key]!)];
  }

  void _addPaths(Iterable<String> paths, String extension) {
    final target = extension == '.hwpx' ? _hwpxByKey : _pdfByKey;
    var skipped = 0;
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || p.extension(path).toLowerCase() != extension) {
        skipped += 1;
        continue;
      }
      final key = _pairKey(path);
      if (key.isEmpty) continue;
      target[key] = path;
    }
    setState(() {
      _message = skipped == 0
          ? ''
          : '$skipped개 파일은 ${extension.substring(1).toUpperCase()} 형식이 아니라 제외했습니다.';
    });
  }

  Future<void> _pickFiles(String extension) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: <String>[extension.substring(1)],
      withData: false,
    );
    if (result == null) return;
    _addPaths(
      result.files
          .map((file) => file.path ?? '')
          .where((path) => path.isNotEmpty),
      extension,
    );
  }

  void _removePair(ExamBatchUploadPair pair) {
    final key = _pairKey(pair.hwpxPath);
    setState(() {
      _hwpxByKey.remove(key);
      _pdfByKey.remove(key);
    });
  }

  void _submit() {
    final pairs = _pairs;
    if (pairs.isEmpty) {
      setState(() => _message = '파일명이 같은 HWPX·PDF 쌍을 하나 이상 등록하세요.');
      return;
    }
    if (pairs.length > maxExamBatchDocuments) {
      setState(
        () => _message = '한 번에 최대 $maxExamBatchDocuments개 문서만 처리할 수 있습니다.',
      );
      return;
    }
    if (_unmatchedHwpx.isNotEmpty || _unmatchedPdf.isNotEmpty) {
      setState(() => _message = '짝이 없는 파일을 제거하거나 같은 이름의 파일을 추가하세요.');
      return;
    }
    Navigator.of(context).pop(pairs);
  }

  @override
  Widget build(BuildContext context) {
    final pairs = _pairs;
    final unmatchedHwpx = _unmatchedHwpx;
    final unmatchedPdf = _unmatchedPdf;
    return Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.all(28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '내신 기출 일괄 등록',
                          style: TextStyle(
                            color: _text,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          '이름이 같은 HWPX와 PDF를 한 쌍으로 묶습니다. 최대 10쌍을 순서대로 처리합니다.',
                          style: TextStyle(color: _textSub, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: _textSub),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _BatchDropZone(
                      title: 'HWPX 파일',
                      subtitle: '최대 10개를 드래그하거나 클릭',
                      icon: Icons.upload_file_outlined,
                      active: _hwpxHover,
                      count: _hwpxByKey.length,
                      accent: _accent,
                      onTap: () => unawaited(_pickFiles('.hwpx')),
                      onEntered: () => setState(() => _hwpxHover = true),
                      onExited: () => setState(() => _hwpxHover = false),
                      onDropped: (paths) {
                        setState(() => _hwpxHover = false);
                        _addPaths(paths, '.hwpx');
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _BatchDropZone(
                      title: 'PDF 파일',
                      subtitle: 'HWPX와 같은 파일명으로 등록',
                      icon: Icons.picture_as_pdf_outlined,
                      active: _pdfHover,
                      count: _pdfByKey.length,
                      accent: const Color(0xFFE57373),
                      onTap: () => unawaited(_pickFiles('.pdf')),
                      onEntered: () => setState(() => _pdfHover = true),
                      onExited: () => setState(() => _pdfHover = false),
                      onDropped: (paths) {
                        setState(() => _pdfHover = false);
                        _addPaths(paths, '.pdf');
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _border),
                  ),
                  child: pairs.isEmpty &&
                          unmatchedHwpx.isEmpty &&
                          unmatchedPdf.isEmpty
                      ? const Center(
                          child: Text(
                            '등록된 파일이 없습니다.',
                            style: TextStyle(color: _textSub),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(10),
                          children: [
                            for (var index = 0; index < pairs.length; index++)
                              _PairRow(
                                index: index,
                                pair: pairs[index],
                                onRemove: () => _removePair(pairs[index]),
                              ),
                            if (unmatchedHwpx.isNotEmpty)
                              _UnmatchedFiles(
                                title: 'PDF 짝이 없는 HWPX',
                                files: unmatchedHwpx,
                              ),
                            if (unmatchedPdf.isNotEmpty)
                              _UnmatchedFiles(
                                title: 'HWPX 짝이 없는 PDF',
                                files: unmatchedPdf,
                              ),
                          ],
                        ),
                ),
              ),
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _message,
                  style: const TextStyle(
                    color: Color(0xFFFFA8AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '완성된 문서 ${pairs.length}/$maxExamBatchDocuments개',
                    style: const TextStyle(
                      color: _textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: pairs.isEmpty ? null : _submit,
                    style: FilledButton.styleFrom(backgroundColor: _accent),
                    icon:
                        const Icon(Icons.playlist_add_check_rounded, size: 18),
                    label: Text('${pairs.length}개 순차 작업 시작'),
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

class _BatchDropZone extends StatelessWidget {
  const _BatchDropZone({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.active,
    required this.count,
    required this.accent,
    required this.onTap,
    required this.onEntered,
    required this.onExited,
    required this.onDropped,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool active;
  final int count;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onEntered;
  final VoidCallback onExited;
  final ValueChanged<List<String>> onDropped;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => onEntered(),
      onDragExited: (_) => onExited(),
      onDragDone: (detail) =>
          onDropped(detail.files.map((file) => file.path).toList()),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 116,
          decoration: BoxDecoration(
            color: active
                ? accent.withValues(alpha: 0.15)
                : _ExamBatchUploadDialogState._field,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? accent : _ExamBatchUploadDialogState._border,
              width: active ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: accent, size: 29),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$title · $count개',
                    style: const TextStyle(
                      color: _ExamBatchUploadDialogState._text,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: _ExamBatchUploadDialogState._textSub,
                      fontSize: 11.5,
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

class _PairRow extends StatelessWidget {
  const _PairRow({
    required this.index,
    required this.pair,
    required this.onRemove,
  });

  final int index;
  final ExamBatchUploadPair pair;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(11, 8, 4, 8),
      decoration: BoxDecoration(
        color: _ExamBatchUploadDialogState._field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _ExamBatchUploadDialogState._border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: _ExamBatchUploadDialogState._textSub,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              pair.baseName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _ExamBatchUploadDialogState._text,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const _FileReadyChip(label: 'HWPX'),
          const SizedBox(width: 5),
          const _FileReadyChip(label: 'PDF'),
          IconButton(
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close,
              size: 17,
              color: _ExamBatchUploadDialogState._textSub,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileReadyChip extends StatelessWidget {
  const _FileReadyChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: _ExamBatchUploadDialogState._accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF73C9A5),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _UnmatchedFiles extends StatelessWidget {
  const _UnmatchedFiles({required this.title, required this.files});

  final String title;
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1B1F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF6E353B)),
      ),
      child: Text(
        '$title: ${files.join(', ')}',
        style: const TextStyle(
          color: Color(0xFFFFA8AF),
          fontSize: 11.5,
          height: 1.4,
        ),
      ),
    );
  }
}
