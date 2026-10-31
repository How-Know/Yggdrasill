import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'mock_exam_models.dart';

/// 모의고사 PDF 를 파일명으로 묶어 확인받는다. 확인하면 읽은 파일 목록을 돌려준다.
Future<List<MockExamFileName>?> showMockExamUploadDialog(
  BuildContext context, {
  required Set<String> existingExamKeys,
}) {
  return showDialog<List<MockExamFileName>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MockExamUploadDialog(existingExamKeys: existingExamKeys),
  );
}

class _MockExamUploadDialog extends StatefulWidget {
  const _MockExamUploadDialog({required this.existingExamKeys});

  final Set<String> existingExamKeys;

  @override
  State<_MockExamUploadDialog> createState() => _MockExamUploadDialogState();
}

class _ExamGroup {
  _ExamGroup(this.head);

  final MockExamFileName head;
  final Map<String, MockExamFileName> problems = <String, MockExamFileName>{};
  final Map<String, MockExamFileName> solutions = <String, MockExamFileName>{};

  List<String> get expectedElectives =>
      head.grade == 3 ? mockExamElectives : const <String>[''];

  bool get hasProblem => problems.isNotEmpty;
  bool get hasSolution => solutions.isNotEmpty;

  /// 문제지가 있는 선택과목인데 해설이 없는 경우.
  List<String> get problemWithoutSolution =>
      problems.keys.where((e) => !solutions.containsKey(e)).toList();

  Iterable<MockExamFileName> get files => [...problems.values, ...solutions.values];
}

class _MockExamUploadDialogState extends State<_MockExamUploadDialog> {
  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF10171A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const Color _danger = Color(0xFFDE6A73);

  final Map<String, MockExamFileName> _byPaper = <String, MockExamFileName>{};
  final List<String> _rejected = <String>[];
  bool _hover = false;

  void _addPaths(Iterable<String> paths) {
    setState(() {
      for (final raw in paths) {
        final path = raw.trim();
        if (path.isEmpty) continue;
        final parsed = parseMockExamFileName(path);
        if (parsed == null) {
          final name = p.basename(path);
          if (!_rejected.contains(name)) _rejected.add(name);
          continue;
        }
        _byPaper[parsed.paperKey] = parsed;
      }
    });
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: const <String>['pdf'],
      withData: false,
    );
    if (result == null) return;
    _addPaths(result.files.map((f) => f.path ?? ''));
  }

  List<_ExamGroup> get _groups {
    final map = <String, _ExamGroup>{};
    for (final f in _byPaper.values) {
      final g = map.putIfAbsent(f.examKey, () => _ExamGroup(f));
      (f.kind == 'problem' ? g.problems : g.solutions)[f.elective] = f;
    }
    final list = map.values.toList()
      ..sort((a, b) {
        final byGrade = a.head.grade.compareTo(b.head.grade);
        if (byGrade != 0) return byGrade;
        final byYear = b.head.examYear.compareTo(a.head.examYear);
        if (byYear != 0) return byYear;
        return a.head.month.compareTo(b.head.month);
      });
    return list;
  }

  void _removeGroup(_ExamGroup group) {
    setState(() {
      for (final f in group.files) {
        _byPaper.remove(f.paperKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final blocked = groups.where((g) => !g.hasProblem).toList();
    final ready = groups.isNotEmpty && blocked.isEmpty;
    return Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.all(28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 780),
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
                          '모의고사 기출 등록',
                          style: TextStyle(
                            color: _text,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          '파일명 예: 2024 고3 11월 수능 (확통).pdf · 2024 고3 11월 수능 (확통) - 해설.pdf · 2024 고1 3월 교육청.pdf',
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
              DropTarget(
                onDragEntered: (_) => setState(() => _hover = true),
                onDragExited: (_) => setState(() => _hover = false),
                onDragDone: (detail) {
                  setState(() => _hover = false);
                  _addPaths(detail.files.map((f) => f.path));
                },
                child: InkWell(
                  onTap: () => unawaited(_pick()),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: 100,
                    decoration: BoxDecoration(
                      color: _hover ? _accent.withValues(alpha: 0.15) : _field,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _hover ? _accent : _border,
                        width: _hover ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.picture_as_pdf_outlined,
                            color: _accent, size: 29),
                        const SizedBox(width: 12),
                        Text(
                          '문제지·해설 PDF를 드래그하거나 클릭 · ${_byPaper.length}개',
                          style: const TextStyle(
                            color: _text,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                  child: groups.isEmpty && _rejected.isEmpty
                      ? const Center(
                          child: Text(
                            '등록된 파일이 없습니다.',
                            style: TextStyle(color: _textSub),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(10),
                          children: [
                            for (final g in groups) _groupRow(g),
                            if (_rejected.isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _danger.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: _danger.withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  '파일명을 읽지 못해 제외: ${_rejected.join(', ')}',
                                  style: const TextStyle(
                                    color: _danger,
                                    fontSize: 11.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              if (blocked.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '문제지가 없는 시험: ${blocked.map((g) => g.head.title).join(', ')}',
                  style: const TextStyle(
                    color: _danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '시험 ${groups.length}회 · 파일 ${_byPaper.length}개',
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
                    onPressed: ready
                        ? () => Navigator.of(context)
                            .pop(_byPaper.values.toList(growable: false))
                        : null,
                    style: FilledButton.styleFrom(backgroundColor: _accent),
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Text('${groups.length}회 업로드 후 추출'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupRow(_ExamGroup g) {
    final exists = widget.existingExamKeys.contains(g.head.examKey);
    final missingSolution = g.problemWithoutSolution;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 210,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.head.title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    '${mockExamSchoolYear(g.head.grade, g.head.examYear)}학년도',
                    if (exists) '등록됨 · 올린 파일만 교체',
                  ].join(' · '),
                  style: TextStyle(
                    color: exists ? const Color(0xFFE3B341) : _textSub,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final e in g.expectedElectives)
                  _chip(
                    '문제 ${e.isEmpty ? '' : mockExamSectionShortLabels[e]}'.trim(),
                    g.problems.containsKey(e),
                  ),
                for (final e in g.expectedElectives)
                  _chip(
                    '해설 ${e.isEmpty ? '' : mockExamSectionShortLabels[e]}'.trim(),
                    g.solutions.containsKey(e),
                  ),
              ],
            ),
          ),
          if (missingSolution.isNotEmpty)
            const Tooltip(
              message: '해설이 없는 선택과목은 정답·해설 위치가 비어 있게 됩니다.',
              child: Icon(Icons.info_outline, size: 17, color: Color(0xFFE3B341)),
            ),
          IconButton(
            onPressed: () => _removeGroup(g),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 17, color: _textSub),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool present) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: present ? _accent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: present ? Colors.transparent : _border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: present ? const Color(0xFF73C9A5) : const Color(0xFF5E6E6E),
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
