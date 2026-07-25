// 문제은행 「필기」 탭 본문.
//
// 학생앱에서 「필기 인식이 잘 안돼요」로 신고된 필기 샘플
// (student_handwriting_samples)을 목록으로 보여주고, 선택한 샘플의
// 필기 원본 렌더·인식 결과·정답을 나란히 확인한 뒤 사용자+AI가 판단해
// 개선 방향(review_note)을 기록한다.
//
// problem_bank_screen.dart 가 16,000줄이 넘어 본문 UI 를 이 파일로 분리했다.
// 색상 토큰(_panel/_field/_text/_textSub 등)은 문제은행 화면과 동일한 값을 쓴다.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../services/problem_bank_service.dart';

class HandwritingReviewTab extends StatefulWidget {
  const HandwritingReviewTab({
    super.key,
    required this.academyId,
    required this.service,
  });

  final String academyId;
  final ProblemBankService service;

  @override
  State<HandwritingReviewTab> createState() => _HandwritingReviewTabState();
}

class _HandwritingReviewTabState extends State<HandwritingReviewTab> {
  // 문제은행 화면과 동일한 다크 패널 토큰.
  static const Color _panel = Color(0xFF10171A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);
  static const Color _danger = Color(0xFFDE6A73);
  static const Color _warn = Color(0xFFE3B341);

  static const Map<String, String> _statusFilterLabels = <String, String>{
    'open': '검토 대기',
    'resolved': '판단 완료',
    'dismissed': '무시됨',
    '': '전체',
  };
  static const Map<String, String> _verdictLabels = <String, String>{
    'recognizer_limit': '인식 모델 한계',
    'ambiguous_writing': '필기 모호',
    'ui_issue': '앱/전처리 문제',
    'other': '기타',
  };

  final GlobalKey _handwritingBoundaryKey = GlobalKey();
  final TextEditingController _reviewNoteCtrl = TextEditingController();

  List<_HandwritingSample> _samples = <_HandwritingSample>[];
  String _statusFilter = 'open';
  String? _selectedId;
  bool _isLoading = false;
  bool _isAssessing = false;
  bool _isSavingReview = false;
  // 선택 샘플의 AI 판단 결과 (저장 전 임시값 포함). 저장 시 p_ai_assessment 로 전달.
  Map<String, dynamic>? _aiAssessment;

  _HandwritingSample? get _selected {
    for (final s in _samples) {
      if (s.id == _selectedId) return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadSamples());
  }

  @override
  void dispose() {
    _reviewNoteCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? _danger : _accent,
        ),
      );
    });
  }

  Future<void> _loadSamples() async {
    final academyId = widget.academyId.trim();
    if (academyId.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final rows = await widget.service.listHandwritingSamples(
        academyId: academyId,
        status: _statusFilter,
      );
      if (!mounted) return;
      final samples = rows
          .map(_HandwritingSample.fromMap)
          .toList(growable: false);
      setState(() {
        _samples = samples;
        // 선택 중이던 샘플이 필터에서 사라지면 첫 샘플로 이동.
        final stillThere = samples.any((s) => s.id == _selectedId);
        if (!stillThere) {
          _applySelection(samples.isEmpty ? null : samples.first);
        } else {
          // 서버 값이 갱신됐을 수 있으므로 선택 샘플 기준으로 다시 동기화.
          _applySelection(_selected);
        }
      });
    } catch (e) {
      _showSnack('필기 샘플 조회 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// setState 안에서 호출된다. 선택 변경 시 메모/AI 판단 상태를 샘플 값으로 리셋.
  void _applySelection(_HandwritingSample? sample) {
    _selectedId = sample?.id;
    _reviewNoteCtrl.text = sample?.reviewNote ?? '';
    _aiAssessment = sample?.aiAssessment;
  }

  Future<String?> _captureHandwritingPngBase64() async {
    final ctx = _handwritingBoundaryKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 2.0);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return base64Encode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  }

  Future<void> _runAiAssessment() async {
    final sample = _selected;
    if (sample == null || _isAssessing) return;
    setState(() => _isAssessing = true);
    try {
      final imageBase64 = await _captureHandwritingPngBase64();
      if (imageBase64 == null || imageBase64.isEmpty) {
        _showSnack('필기 이미지를 캡처하지 못했습니다.', error: true);
        return;
      }
      final assessment = await widget.service.assessHandwritingSample(
        imageBase64: imageBase64,
        recognizedText: sample.recognizedText,
        recognizedCandidates: sample.recognizedCandidates,
        expectedAnswer: sample.expectedAnswer,
        expectedAnswerKind: sample.expectedAnswerKind,
        submittedAnswer: sample.submittedAnswer,
        note: sample.note,
      );
      if (!mounted) return;
      setState(() => _aiAssessment = assessment);
      _showSnack('AI 판단을 받았습니다. 내용을 확인하고 리뷰를 저장하세요.');
    } catch (_) {
      _showSnack('AI 판단을 사용할 수 없어요(게이트웨이 연결 실패)', error: true);
    } finally {
      if (mounted) setState(() => _isAssessing = false);
    }
  }

  Future<void> _saveReview(String status) async {
    final sample = _selected;
    if (sample == null || _isSavingReview) return;
    setState(() => _isSavingReview = true);
    try {
      await widget.service.reviewHandwritingSample(
        sampleId: sample.id,
        status: status,
        reviewNote: _reviewNoteCtrl.text.trim(),
        aiAssessment: _aiAssessment,
      );
      if (!mounted) return;
      switch (status) {
        case 'resolved':
          _showSnack('판단 완료로 저장했습니다.');
          break;
        case 'dismissed':
          _showSnack('무시 처리했습니다.');
          break;
        default:
          _showSnack('다시 검토 대기로 되돌렸습니다.');
      }
      await _loadSamples();
    } catch (e) {
      _showSnack('리뷰 저장 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _isSavingReview = false);
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    final local = time.toLocal();
    return '${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'resolved':
        return _accent;
      case 'dismissed':
        return _textSub;
      default:
        return _warn;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'resolved':
        return '판단 완료';
      case 'dismissed':
        return '무시됨';
      default:
        return '검토 대기';
    }
  }

  Widget _buildStatusBadge(String status) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 380, child: _buildListPanel()),
        const SizedBox(width: 12),
        Expanded(child: _buildDetailPanel()),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 좌측: 샘플 목록
  // -------------------------------------------------------------------------

  Widget _buildListPanel() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '필기 인식 리뷰',
            style: TextStyle(
              color: _text,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '학생앱에서 「필기 인식이 잘 안돼요」로 신고된 필기 샘플을 검토합니다.',
            style: TextStyle(color: _textSub, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _statusFilter,
            dropdownColor: _panel,
            decoration: const InputDecoration(
              labelText: '상태',
              labelStyle: TextStyle(color: _textSub),
              filled: true,
              fillColor: _field,
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _accent),
              ),
            ),
            style: const TextStyle(color: _text),
            items: [
              for (final entry in _statusFilterLabels.entries)
                DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
            ],
            onChanged: (value) {
              setState(() => _statusFilter = value ?? 'open');
              unawaited(_loadSamples());
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : () => unawaited(_loadSamples()),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 16),
              label: Text(_isLoading ? '조회 중...' : '새로고침'),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '샘플 ${_samples.length}건',
            style: const TextStyle(
              color: _textSub,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _samples.isEmpty
                ? const Center(
                    child: Text(
                      '표시할 필기 샘플이 없습니다.',
                      style: TextStyle(color: _textSub),
                    ),
                  )
                : ListView.separated(
                    itemCount: _samples.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _buildSampleCard(_samples[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSampleCard(_HandwritingSample sample) {
    final selected = sample.id == _selectedId;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (sample.id == _selectedId) return;
          setState(() => _applySelection(sample));
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _field,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _accent : _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sample.studentName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildStatusBadge(sample.reviewStatus),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                sample.locationLabel,
                style: const TextStyle(
                  color: _textSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '접수 ${_formatTime(sample.createdAt)}',
                style: const TextStyle(color: _textSub, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 우측: 선택 샘플 상세
  // -------------------------------------------------------------------------

  Widget _buildDetailPanel() {
    final sample = _selected;
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: sample == null
          ? const Center(
              child: Text(
                '좌측 목록에서 필기 샘플을 선택하세요.',
                style: TextStyle(color: _textSub),
              ),
            )
          : ListView(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${sample.studentName} · ${sample.locationLabel}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '접수 ${_formatTime(sample.createdAt)}',
                      style: const TextStyle(color: _textSub, fontSize: 11.5),
                    ),
                    const SizedBox(width: 8),
                    _buildStatusBadge(sample.reviewStatus),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSectionTitle('학생 필기'),
                const SizedBox(height: 8),
                _buildHandwritingCanvas(sample),
                const SizedBox(height: 14),
                _buildSectionTitle('인식 결과 · 정답 비교'),
                const SizedBox(height: 8),
                _buildComparisonSection(sample),
                const SizedBox(height: 14),
                _buildSectionTitle('AI 판단'),
                const SizedBox(height: 8),
                _buildAiSection(sample),
                const SizedBox(height: 14),
                _buildSectionTitle('개선 방향 · 리뷰'),
                const SizedBox(height: 8),
                _buildReviewSection(sample),
              ],
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: _textSub,
        fontSize: 12.5,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  Widget _buildHandwritingCanvas(_HandwritingSample sample) {
    if (sample.strokes.isEmpty) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _field,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: const Text(
          '필기 획 데이터가 없습니다.',
          style: TextStyle(color: _textSub),
        ),
      );
    }
    final aspectRatio =
        (sample.canvasWidth > 0 && sample.canvasHeight > 0)
            ? sample.canvasWidth / sample.canvasHeight
            : 3.0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: RepaintBoundary(
              key: _handwritingBoundaryKey,
              child: CustomPaint(
                painter: _HandwritingPainter(
                  strokes: sample.strokes,
                  canvasWidth: sample.canvasWidth,
                  canvasHeight: sample.canvasHeight,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, {Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: _textSub,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? '-' : value,
            style: const TextStyle(
              color: _text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonSection(_HandwritingSample sample) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildInfoTile('인식 결과', sample.recognizedText),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildInfoTile('제출된 답', sample.submittedAnswer),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildInfoTile(
                '문항 정답',
                sample.expectedAnswer,
                trailing: sample.expectedAnswerKind.isEmpty
                    ? null
                    : Text(
                        sample.expectedAnswerKind,
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ),
          ],
        ),
        if (sample.recognizedCandidates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _field,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '인식 후보',
                  style: TextStyle(
                    color: _textSub,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final candidate in sample.recognizedCandidates)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: _border),
                        ),
                        child: Text(
                          candidate,
                          style: const TextStyle(
                            color: _text,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (sample.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildInfoTile('학생 메모', sample.note),
        ],
      ],
    );
  }

  Widget _buildAiSection(_HandwritingSample sample) {
    final assessment = _aiAssessment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          onPressed: (_isAssessing || sample.strokes.isEmpty)
              ? null
              : () => unawaited(_runAiAssessment()),
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
          ),
          icon: _isAssessing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.auto_awesome, size: 16),
          label: Text(_isAssessing ? 'AI 판단 중...' : 'AI 판단'),
        ),
        if (assessment != null) ...[
          const SizedBox(height: 10),
          _buildAssessmentCard(assessment),
        ],
      ],
    );
  }

  Widget _buildAssessmentCard(Map<String, dynamic> assessment) {
    final verdict = '${assessment['verdict'] ?? ''}'.trim();
    final verdictLabel = _verdictLabels[verdict] ?? (verdict.isEmpty ? '기타' : verdict);
    final readAs = '${assessment['read_as'] ?? ''}'.trim();
    final cause = '${assessment['cause'] ?? ''}'.trim();
    final improvement = '${assessment['improvement'] ?? ''}'.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _accent),
                ),
                child: Text(
                  verdictLabel,
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (readAs.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '사람 눈으로 읽으면: $readAs',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _textSub,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (cause.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '원인: $cause',
              style: const TextStyle(color: _text, fontSize: 13, height: 1.4),
            ),
          ],
          if (improvement.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '개선 방향: $improvement',
              style: const TextStyle(color: _text, fontSize: 13, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewSection(_HandwritingSample sample) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _reviewNoteCtrl,
          maxLines: 3,
          style: const TextStyle(color: _text, fontSize: 13.5),
          decoration: const InputDecoration(
            labelText: '개선 방향 메모',
            hintText: '사용자+AI가 합의한 최종 개선 방향을 기록하세요.',
            labelStyle: TextStyle(color: _textSub),
            hintStyle: TextStyle(color: _textSub, fontSize: 12.5),
            filled: true,
            fillColor: _field,
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _border),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _accent),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: (_isSavingReview || sample.reviewStatus == 'resolved')
                  ? null
                  : () => unawaited(_saveReview('resolved')),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('판단 완료'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: (_isSavingReview || sample.reviewStatus == 'dismissed')
                  ? null
                  : () => unawaited(_saveReview('dismissed')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _danger,
                side: const BorderSide(color: _danger),
              ),
              icon: const Icon(Icons.block_outlined, size: 16),
              label: const Text('무시'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: (_isSavingReview || sample.reviewStatus == 'open')
                  ? null
                  : () => unawaited(_saveReview('open')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textSub,
                side: const BorderSide(color: _border),
              ),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 열기'),
            ),
            if (_isSavingReview) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _accent,
                ),
              ),
            ],
          ],
        ),
        if (sample.reviewedAt != null) ...[
          const SizedBox(height: 8),
          Text(
            '마지막 리뷰 ${_formatTime(sample.reviewedAt)}',
            style: const TextStyle(color: _textSub, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 데이터 모델
// ---------------------------------------------------------------------------

class _HandwritingStroke {
  const _HandwritingStroke({required this.x, required this.y});

  final List<double> x;
  final List<double> y;
}

class _HandwritingSample {
  const _HandwritingSample({
    required this.id,
    required this.createdAt,
    required this.studentName,
    required this.bookName,
    required this.gradeLabel,
    required this.problemNumber,
    required this.displayPage,
    required this.recognizedText,
    required this.recognizedCandidates,
    required this.submittedAnswer,
    required this.expectedAnswer,
    required this.expectedAnswerKind,
    required this.note,
    required this.reviewStatus,
    required this.aiAssessment,
    required this.reviewNote,
    required this.reviewedAt,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.strokes,
  });

  final String id;
  final DateTime? createdAt;
  final String studentName;
  final String bookName;
  final String gradeLabel;
  final String problemNumber;
  final int? displayPage;
  final String recognizedText;
  final List<String> recognizedCandidates;
  final String submittedAnswer;
  final String expectedAnswer;
  final String expectedAnswerKind;
  final String note;
  final String reviewStatus;
  final Map<String, dynamic>? aiAssessment;
  final String reviewNote;
  final DateTime? reviewedAt;
  final double canvasWidth;
  final double canvasHeight;
  final List<_HandwritingStroke> strokes;

  String get locationLabel {
    final parts = <String>[
      if (bookName.isNotEmpty) bookName,
      if (displayPage != null) 'p.$displayPage',
      if (problemNumber.isNotEmpty) '$problemNumber번',
    ];
    return parts.isEmpty ? '교재 문항' : parts.join(' · ');
  }

  static List<double> _numList(dynamic value) {
    if (value is! List) return const <double>[];
    return value
        .map((e) => e is num ? e.toDouble() : double.tryParse('$e') ?? 0.0)
        .toList(growable: false);
  }

  static _HandwritingSample fromMap(Map<String, dynamic> map) {
    final payload = map['payload'] is Map
        ? Map<String, dynamic>.from(map['payload'] as Map)
        : const <String, dynamic>{};
    final strokes = <_HandwritingStroke>[];
    final rawStrokes = payload['strokes'];
    if (rawStrokes is List) {
      for (final raw in rawStrokes) {
        if (raw is! Map) continue;
        final x = _numList(raw['x']);
        final y = _numList(raw['y']);
        if (x.isEmpty || y.isEmpty) continue;
        strokes.add(_HandwritingStroke(x: x, y: y));
      }
    }
    final candidates = payload['recognized_candidates'] is List
        ? (payload['recognized_candidates'] as List)
            .map((e) => '$e'.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final displayPage =
        int.tryParse('${map['display_page'] ?? map['raw_page'] ?? ''}');
    return _HandwritingSample(
      id: '${map['id'] ?? ''}',
      createdAt: DateTime.tryParse('${map['created_at'] ?? ''}'),
      studentName: '${map['student_name'] ?? '학생'}'.trim(),
      bookName: '${map['book_name'] ?? ''}'.trim(),
      gradeLabel: '${map['grade_label'] ?? ''}'.trim(),
      problemNumber: '${map['problem_number'] ?? ''}'.trim(),
      displayPage: displayPage,
      recognizedText: '${map['recognized_text'] ?? ''}'.trim(),
      recognizedCandidates: candidates,
      submittedAnswer: '${map['submitted_answer'] ?? ''}'.trim(),
      expectedAnswer: '${map['expected_answer'] ?? ''}'.trim(),
      expectedAnswerKind: '${map['expected_answer_kind'] ?? ''}'.trim(),
      note: '${map['note'] ?? ''}'.trim(),
      reviewStatus: '${map['review_status'] ?? 'open'}'.trim(),
      aiAssessment: map['ai_assessment'] is Map
          ? Map<String, dynamic>.from(map['ai_assessment'] as Map)
          : null,
      reviewNote: '${map['review_note'] ?? ''}'.trim(),
      reviewedAt: DateTime.tryParse('${map['reviewed_at'] ?? ''}'),
      canvasWidth:
          double.tryParse('${payload['canvas_width'] ?? ''}') ?? 0.0,
      canvasHeight:
          double.tryParse('${payload['canvas_height'] ?? ''}') ?? 0.0,
      strokes: strokes,
    );
  }
}

// ---------------------------------------------------------------------------
// 필기 렌더러: payload.strokes 를 흰 배경/검정 폴리라인으로 그린다.
// ---------------------------------------------------------------------------

class _HandwritingPainter extends CustomPainter {
  _HandwritingPainter({
    required this.strokes,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final List<_HandwritingStroke> strokes;
  final double canvasWidth;
  final double canvasHeight;

  @override
  void paint(Canvas canvas, Size size) {
    // AI 판단용 PNG 캡처에 그대로 쓰이므로 배경도 페인터가 직접 채운다.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (strokes.isEmpty || canvasWidth <= 0 || canvasHeight <= 0) return;

    // 원본 캔버스 비율을 유지한 채 위젯 크기에 맞춰 균등 스케일.
    final scale = math.min(size.width / canvasWidth, size.height / canvasHeight);
    final dx = (size.width - canvasWidth * scale) / 2;
    final dy = (size.height - canvasHeight * scale) / 2;

    final strokePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = (2.75 * scale).clamp(1.5, 5.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final stroke in strokes) {
      final count = math.min(stroke.x.length, stroke.y.length);
      if (count == 0) continue;
      if (count == 1) {
        // 점 하나짜리 획은 원으로 찍는다.
        canvas.drawCircle(
          Offset(dx + stroke.x[0] * scale, dy + stroke.y[0] * scale),
          strokePaint.strokeWidth / 2,
          Paint()..color = Colors.black,
        );
        continue;
      }
      final path = Path()
        ..moveTo(dx + stroke.x[0] * scale, dy + stroke.y[0] * scale);
      for (var i = 1; i < count; i++) {
        path.lineTo(dx + stroke.x[i] * scale, dy + stroke.y[i] * scale);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.canvasWidth != canvasWidth ||
        oldDelegate.canvasHeight != canvasHeight;
  }
}
