import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/mock_exam_service.dart';
import 'mock_exam_models.dart';
import 'mock_exam_upload_dialog.dart';

const Color _panel = Color(0xFF10171A);
const Color _field = Color(0xFF15171C);
const Color _border = Color(0xFF223131);
const Color _text = Color(0xFFEAF2F2);
const Color _textSub = Color(0xFF9FB3B3);
const Color _accent = Color(0xFF33A373);
const Color _danger = Color(0xFFDE6A73);
const Color _warn = Color(0xFFE3B341);

/// "모의고사 페이지 검수" 왼쪽 목록. 내신 기출 목록과 같은 모양으로
/// 학년 → 연도 → 회차 → 구간 문서를 보여 주고, 문서를 누르면 기존 문항 표에 연다.
class MockExamQuickSwitchPanel extends StatefulWidget {
  const MockExamQuickSwitchPanel({
    super.key,
    required this.academyId,
    required this.activeDocumentId,
    required this.onOpenDocument,
  });

  final String academyId;
  final String? activeDocumentId;
  final Future<void> Function(String documentId) onOpenDocument;

  @override
  State<MockExamQuickSwitchPanel> createState() =>
      MockExamQuickSwitchPanelState();
}

class MockExamQuickSwitchPanelState extends State<MockExamQuickSwitchPanel> {
  final MockExamService _service = MockExamService();

  List<MockExam> _exams = const <MockExam>[];
  Map<String, List<MockExamSectionLink>> _links =
      const <String, List<MockExamSectionLink>>{};
  bool _loading = true;
  String _error = '';
  bool _autoOpened = false;
  final Set<String> _expanded = <String>{};

  bool _uploading = false;
  String _uploadMessage = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get _hasActiveWork =>
      _exams.any((e) => e.isBusy) ||
      _links.values.expand((l) => l).any(
            (s) => s.extractStatus == 'queued' || s.extractStatus == 'extracting',
          );

  Future<void> _tick() async {
    if (!mounted || _uploading || !_hasActiveWork) return;
    await _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>([
        _service.listExams(widget.academyId),
        _service.listSectionLinks(widget.academyId),
      ]);
      if (!mounted) return;
      setState(() {
        _exams = results[0] as List<MockExam>;
        _links = results[1] as Map<String, List<MockExamSectionLink>>;
        _loading = false;
        _error = '';
      });
      _expandActive();
      if (!_autoOpened) {
        _autoOpened = true;
        await _openFirstIfNone();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  List<MockExamSectionLink> _sectionsOf(MockExam exam) {
    final links = _links[exam.id] ?? const <MockExamSectionLink>[];
    final order = mockExamSectionsOf(exam.grade);
    return links.where((l) => l.pbDocumentId != null).toList()
      ..sort(
        (a, b) => order.indexOf(a.section).compareTo(order.indexOf(b.section)),
      );
  }

  MockExam? _examOfDocument(String? documentId) {
    if (documentId == null) return null;
    for (final exam in _exams) {
      if (_sectionsOf(exam).any((l) => l.pbDocumentId == documentId)) {
        return exam;
      }
    }
    return null;
  }

  void _expandActive() {
    final exam = _examOfDocument(widget.activeDocumentId);
    if (exam == null) return;
    setState(() {
      _expanded
        ..add('${exam.grade}')
        ..add('${exam.grade}|${exam.examYear}')
        ..add(exam.id);
    });
  }

  Future<void> _openFirstIfNone() async {
    if (_examOfDocument(widget.activeDocumentId) != null) return;
    for (final exam in _exams) {
      final sections = _sectionsOf(exam);
      if (sections.isEmpty) continue;
      setState(() {
        _expanded
          ..add('${exam.grade}')
          ..add('${exam.grade}|${exam.examYear}')
          ..add(exam.id);
      });
      await widget.onOpenDocument(sections.first.pbDocumentId!);
      return;
    }
  }

  void _snack(String message, {bool error = false}) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? _danger : const Color(0xFF2A2A2A),
      ),
    );
  }

  bool get isUploading => _uploading;

  Future<void> upload() async {
    if (_uploading) return;
    final keys = {
      for (final e in _exams) '${e.grade}|${e.examYear}|${e.month}|${e.org}',
    };
    final files =
        await showMockExamUploadDialog(context, existingExamKeys: keys);
    if (files == null || files.isEmpty || !mounted) return;
    setState(() {
      _uploading = true;
      _uploadMessage = '업로드 준비 중';
    });
    try {
      final ids = await _service.uploadBatch(
        academyId: widget.academyId,
        files: files,
        onProgress: (m) {
          if (mounted) setState(() => _uploadMessage = m);
        },
      );
      if (!mounted) return;
      setState(() => _uploadMessage = '${ids.length}회 업로드 완료 · 추출 대기');
      _snack('${ids.length}회를 올렸습니다. 추출이 끝나면 목록에 문서가 생깁니다.');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadMessage = '업로드 실패: $e');
      _snack('업로드 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _rerun(MockExam exam, String request) async {
    const labels = <String, String>{
      'all': '문항 영역·해설·문제은행 추출을 모두 다시 합니다.',
      'solutions': '해설지에서 정답과 해설 위치만 다시 읽습니다.',
      'problem_bank': '구간 문서의 문항을 다시 추출합니다. 문항 표에서 고친 내용은 덮어씁니다.',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text(exam.displayTitle, style: const TextStyle(color: _text)),
        content: Text(
          labels[request] ?? '',
          style: const TextStyle(color: _textSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('다시 추출'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.requestExtraction(exam.id, request);
      await _load(silent: true);
    } catch (e) {
      _snack('요청 실패: $e', error: true);
    }
  }

  void _toggle(String key) => setState(() {
        if (!_expanded.remove(key)) _expanded.add(key);
      });

  @override
  Widget build(BuildContext context) {
    final byGrade = <int, Map<int, List<MockExam>>>{};
    for (final e in _exams) {
      byGrade
          .putIfAbsent(e.grade, () => <int, List<MockExam>>{})
          .putIfAbsent(e.examYear, () => <MockExam>[])
          .add(e);
    }
    final grades = byGrade.keys.toList()..sort();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, color: _accent, size: 18),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  '전체 모의고사',
                  style: TextStyle(
                    color: _text,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${_exams.length}회',
                style: const TextStyle(color: _textSub, fontSize: 11),
              ),
            ],
          ),
          if (_uploadMessage.isNotEmpty) ...[
            const SizedBox(height: 9),
            if (_uploading)
              const LinearProgressIndicator(
                color: _accent,
                backgroundColor: _field,
              ),
            const SizedBox(height: 5),
            Text(
              _uploadMessage,
              style: const TextStyle(color: _textSub, fontSize: 10.5),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: _border),
          ),
          const Text(
            '모의고사 · 학년 → 연도 → 회차 → 문서',
            style: TextStyle(
              color: _textSub,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                color: _accent,
                backgroundColor: _field,
              ),
            )
          else if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '목록을 불러오지 못했습니다: $_error',
                style: const TextStyle(color: _danger, fontSize: 12),
              ),
            )
          else if (grades.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '등록된 모의고사가 없습니다.',
                style: TextStyle(color: _textSub, fontSize: 12),
              ),
            )
          else
            for (final grade in grades) _buildGradeNode(grade, byGrade[grade]!),
        ],
      ),
    );
  }

  Widget _buildGradeNode(int grade, Map<int, List<MockExam>> byYear) {
    final key = '$grade';
    final expanded = _expanded.contains(key);
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => _toggle(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  color: _textSub,
                  size: 18,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '고$grade',
                    style: const TextStyle(
                      color: _text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${byYear.values.fold<int>(0, (sum, l) => sum + l.length)}',
                  style: const TextStyle(color: _textSub, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 15),
            child: Column(
              children: [
                for (final year in years)
                  _buildYearNode(grade, year, byYear[year]!),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildYearNode(int grade, int year, List<MockExam> exams) {
    final key = '$grade|$year';
    final expanded = _expanded.contains(key);
    final sorted = [...exams]..sort((a, b) => a.month.compareTo(b.month));
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => _toggle(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                  color: _textSub,
                  size: 16,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '$year',
                    style: const TextStyle(
                      color: _textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${exams.length}',
                  style: const TextStyle(color: _textSub, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 17),
            child: Column(
              children: [for (final exam in sorted) _buildExamNode(exam)],
            ),
          ),
      ],
    );
  }

  Widget _buildExamNode(MockExam exam) {
    final expanded = _expanded.contains(exam.id);
    final sections = _sectionsOf(exam);
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => _toggle(exam.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 0, 2),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  color: _textSub,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${exam.month}월 ${mockExamOrgLabels[exam.org] ?? exam.org}',
                    style: const TextStyle(
                      color: _textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _statusChip(exam),
                PopupMenuButton<String>(
                  tooltip: '다시 추출',
                  enabled: !exam.isBusy,
                  color: _panel,
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  icon: const Icon(Icons.more_vert, color: _textSub, size: 16),
                  onSelected: (v) => unawaited(_rerun(exam, v)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'all',
                      child: Text('전체 다시 추출', style: TextStyle(color: _text)),
                    ),
                    PopupMenuItem(
                      value: 'solutions',
                      child: Text('해설만 다시 읽기', style: TextStyle(color: _text)),
                    ),
                    PopupMenuItem(
                      value: 'problem_bank',
                      child: Text(
                        '문항만 다시 추출',
                        style: TextStyle(color: _text),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 17),
            child: Column(
              children: [
                if (sections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      exam.status == 'failed' && exam.lastError.isNotEmpty
                          ? exam.lastError
                          : '추출이 끝나면 문서가 생깁니다.',
                      style: const TextStyle(color: _textSub, fontSize: 11),
                    ),
                  )
                else
                  for (final link in sections) _buildDocumentRow(exam, link),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDocumentRow(MockExam exam, MockExamSectionLink link) {
    final selected = widget.activeDocumentId == link.pbDocumentId;
    final missing = exam.missing[link.section];
    final missingCount = missing == null
        ? 0
        : missing.values.fold<int>(0, (sum, l) => sum + l.length);
    final (String label, Color color) = switch (link) {
      _ when link.documentStatus == 'ready' => ('확정', const Color(0xFF41B883)),
      _ when link.extractStatus == 'queued' ||
            link.extractStatus == 'extracting' =>
        ('추출중', _textSub),
      _ when link.extractStatus == 'failed' => ('실패', _danger),
      _ => ('작업중', _warn),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => unawaited(widget.onOpenDocument(link.pbDocumentId!)),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _accent.withValues(alpha: 0.16) : _field,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: selected ? _accent : _border),
        ),
        child: Row(
          children: [
            Icon(
              Icons.description_outlined,
              color: selected ? _accent : _textSub,
              size: 15,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                mockExamSectionLabels[link.section] ?? link.section,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? _text : _textSub,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (missingCount > 0) ...[
              Text(
                '누락 $missingCount',
                style: const TextStyle(
                  color: _warn,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: color.withValues(alpha: 0.55)),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(MockExam exam) {
    final (String label, Color color) = switch (exam.status) {
      'queued' => ('대기', _textSub),
      'running' => (exam.stage == 'solutions' ? '해설 판독' : '문항 판독', _accent),
      'failed' => ('실패', _danger),
      _ => ('', _textSub),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
