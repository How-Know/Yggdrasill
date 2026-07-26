// 문제은행 「채점」 탭 본문.
//
// 학생앱 자동 채점에서 수학적 동치 판정이 개입한 케이스
// (student_grading_equiv_logs)를 목록으로 보여주고, 정답·학생 답·판정
// 내역을 확인한 뒤 교사가 동치 여부를 확정한다.
// 「판정(결정적/AI) + 교사 확정」 쌍이 향후 자체 서술형 채점 AI 의
// 학습 데이터가 된다.
//
// 색상 토큰(_panel/_field/_text/_textSub 등)은 문제은행 화면과 동일한 값.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/problem_bank_service.dart';

class GradingEquivTab extends StatefulWidget {
  const GradingEquivTab({
    super.key,
    required this.academyId,
    required this.service,
  });

  final String academyId;
  final ProblemBankService service;

  @override
  State<GradingEquivTab> createState() => _GradingEquivTabState();
}

class _GradingEquivTabState extends State<GradingEquivTab> {
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
  static const Map<String, String> _methodLabels = <String, String>{
    'deterministic': '결정적 동치',
    'ai_unit': 'AI 단위 판정',
    'ai_equiv': 'AI 표현 동치',
  };
  static const Map<String, String> _flagLabels = <String, String>{
    'form_differs': '표기 다름',
    'unit_hint': '단위 힌트',
    'unit_caution': '단위 주의',
  };

  final TextEditingController _reviewNoteCtrl = TextEditingController();

  List<_EquivLog> _logs = <_EquivLog>[];
  String _statusFilter = 'open';
  String? _selectedId;
  bool _isLoading = false;
  bool _isSaving = false;

  _EquivLog? get _selected {
    for (final log in _logs) {
      if (log.id == _selectedId) return log;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadLogs());
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

  Future<void> _loadLogs() async {
    final academyId = widget.academyId.trim();
    if (academyId.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final rows = await widget.service.listGradingEquivLogs(
        academyId: academyId,
        status: _statusFilter,
      );
      if (!mounted) return;
      final logs = rows.map(_EquivLog.fromMap).toList(growable: false);
      setState(() {
        _logs = logs;
        final stillThere = logs.any((log) => log.id == _selectedId);
        if (!stillThere) {
          _applySelection(logs.isEmpty ? null : logs.first);
        } else {
          _applySelection(_selected);
        }
      });
    } catch (e) {
      _showSnack('채점 로그 조회 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// setState 안에서 호출된다. 선택 변경 시 메모를 로그 값으로 리셋.
  void _applySelection(_EquivLog? log) {
    _selectedId = log?.id;
    _reviewNoteCtrl.text = log?.reviewNote ?? '';
  }

  Future<void> _saveReview(String status, {String? teacherVerdict}) async {
    final log = _selected;
    if (log == null || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await widget.service.reviewGradingEquivLog(
        logId: log.id,
        status: status,
        teacherVerdict: teacherVerdict,
        reviewNote: _reviewNoteCtrl.text.trim(),
      );
      if (!mounted) return;
      switch (teacherVerdict) {
        case 'equivalent':
          _showSnack('「동치 맞음」으로 확정했습니다.');
          break;
        case 'not_equivalent':
          _showSnack('「동치 아님」으로 확정했습니다.');
          break;
        default:
          _showSnack(status == 'dismissed'
              ? '무시 처리했습니다.'
              : status == 'open'
                  ? '다시 검토 대기로 되돌렸습니다.'
                  : '저장했습니다.');
      }
      await _loadLogs();
    } catch (e) {
      _showSnack('리뷰 저장 실패: $e', error: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
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

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
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
  // 좌측: 로그 목록
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
            '동치 채점 리뷰',
            style: TextStyle(
              color: _text,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '자동 채점에서 수학적 동치 판정(결정적/AI)이 개입한 케이스를 '
            '검토하고 교사가 동치 여부를 확정합니다.',
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
              unawaited(_loadLogs());
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : () => unawaited(_loadLogs()),
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
            '판정 로그 ${_logs.length}건',
            style: const TextStyle(
              color: _textSub,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _logs.isEmpty
                ? const Center(
                    child: Text(
                      '표시할 판정 로그가 없습니다.',
                      style: TextStyle(color: _textSub),
                    ),
                  )
                : ListView.separated(
                    itemCount: _logs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _buildLogCard(_logs[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(_EquivLog log) {
    final selected = log.id == _selectedId;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (log.id == _selectedId) return;
          setState(() => _applySelection(log));
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
                  if (log.logNo > 0) ...[
                    Text(
                      '#${log.logNo}',
                      style: const TextStyle(
                        color: _accent,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      log.studentName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildBadge(
                    _statusLabel(log.reviewStatus),
                    _statusColor(log.reviewStatus),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                log.locationLabel,
                style: const TextStyle(
                  color: _textSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _buildBadge(
                    _methodLabels[log.method] ?? log.method,
                    log.method == 'deterministic' ? _accent : _warn,
                  ),
                  const SizedBox(width: 6),
                  _buildBadge(
                    log.finalCorrect ? '정답 처리' : '오답 처리',
                    log.finalCorrect ? _accent : _danger,
                  ),
                  const Spacer(),
                  Text(
                    _formatTime(log.createdAt),
                    style: const TextStyle(color: _textSub, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 우측: 선택 로그 상세
  // -------------------------------------------------------------------------

  Widget _buildDetailPanel() {
    final log = _selected;
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(16),
      child: log == null
          ? const Center(
              child: Text(
                '좌측 목록에서 판정 로그를 선택하세요.',
                style: TextStyle(color: _textSub),
              ),
            )
          : ListView(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${log.logNo > 0 ? '#${log.logNo} · ' : ''}'
                        '${log.studentName} · ${log.locationLabel}',
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
                      '접수 ${_formatTime(log.createdAt)}',
                      style: const TextStyle(color: _textSub, fontSize: 11.5),
                    ),
                    const SizedBox(width: 8),
                    _buildBadge(
                      _statusLabel(log.reviewStatus),
                      _statusColor(log.reviewStatus),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSectionTitle('정답 · 학생 답 비교'),
                const SizedBox(height: 8),
                _buildComparisonSection(log),
                const SizedBox(height: 14),
                _buildSectionTitle('판정 내역'),
                const SizedBox(height: 8),
                _buildVerdictSection(log),
                const SizedBox(height: 14),
                _buildSectionTitle('교사 확정 · 리뷰'),
                const SizedBox(height: 8),
                _buildReviewSection(log),
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

  Widget _buildComparisonSection(_EquivLog log) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildInfoTile(
            '문항 정답',
            log.expectedAnswer,
            trailing: log.partKey.isEmpty
                ? null
                : Text(
                    '파트 ${log.partKey}',
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildInfoTile('학생 답', log.submittedAnswer),
        ),
      ],
    );
  }

  String _boolLabel(bool? value, {String yes = '예', String no = '아니오'}) {
    if (value == null) return '-';
    return value ? yes : no;
  }

  Widget _buildVerdictSection(_EquivLog log) {
    return Container(
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
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _buildBadge(
                _methodLabels[log.method] ?? log.method,
                log.method == 'deterministic' ? _accent : _warn,
              ),
              _buildBadge(
                log.finalCorrect ? '최종 정답 처리' : '최종 오답 처리',
                log.finalCorrect ? _accent : _danger,
              ),
              for (final flag in log.flags)
                _buildBadge(_flagLabels[flag] ?? flag, _textSub),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '결정적 판정: ${log.deterministicCorrect ? '동치(정답)' : '불일치'}',
            style: const TextStyle(color: _text, fontSize: 13, height: 1.4),
          ),
          if (log.method == 'ai_equiv')
            Text(
              'AI 표현 동치 판정: '
              '${_boolLabel(log.aiEquivalent, yes: '동치', no: '동치 아님')}',
              style: const TextStyle(color: _text, fontSize: 13, height: 1.4),
            ),
          if (log.method == 'ai_unit')
            Text(
              'AI 단위 지정 판정: '
              '${_boolLabel(log.aiUnitSpecified, yes: '발문이 단위 지정', no: '지정 없음')}',
              style: const TextStyle(color: _text, fontSize: 13, height: 1.4),
            ),
          if (log.teacherVerdict.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '교사 확정: '
              '${log.teacherVerdict == 'equivalent' ? '동치 맞음' : '동치 아님'}',
              style: const TextStyle(
                color: _accent,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewSection(_EquivLog log) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _reviewNoteCtrl,
          maxLines: 3,
          style: const TextStyle(color: _text, fontSize: 13.5),
          decoration: const InputDecoration(
            labelText: '리뷰 메모',
            hintText: '판정 근거나 개선 방향을 기록하세요.',
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
              onPressed: _isSaving
                  ? null
                  : () => unawaited(
                      _saveReview('resolved', teacherVerdict: 'equivalent')),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('동치 맞음'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _isSaving
                  ? null
                  : () => unawaited(_saveReview('resolved',
                      teacherVerdict: 'not_equivalent')),
              style: FilledButton.styleFrom(
                backgroundColor: _danger,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.cancel_outlined, size: 16),
              label: const Text('동치 아님'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: (_isSaving || log.reviewStatus == 'dismissed')
                  ? null
                  : () => unawaited(_saveReview('dismissed')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textSub,
                side: const BorderSide(color: _border),
              ),
              icon: const Icon(Icons.block_outlined, size: 16),
              label: const Text('무시'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: (_isSaving || log.reviewStatus == 'open')
                  ? null
                  : () => unawaited(_saveReview('open')),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textSub,
                side: const BorderSide(color: _border),
              ),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 열기'),
            ),
            if (_isSaving) ...[
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
        if (log.reviewedAt != null) ...[
          const SizedBox(height: 8),
          Text(
            '마지막 리뷰 ${_formatTime(log.reviewedAt)}',
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

class _EquivLog {
  const _EquivLog({
    required this.id,
    required this.logNo,
    required this.createdAt,
    required this.studentName,
    required this.bookName,
    required this.problemNumber,
    required this.displayPage,
    required this.partKey,
    required this.expectedAnswer,
    required this.submittedAnswer,
    required this.method,
    required this.flags,
    required this.deterministicCorrect,
    required this.aiEquivalent,
    required this.aiUnitSpecified,
    required this.finalCorrect,
    required this.reviewStatus,
    required this.teacherVerdict,
    required this.reviewNote,
    required this.reviewedAt,
  });

  final String id;

  /// 접수 순서대로 붙는 고정 번호 — 「#3」처럼 로그 지칭용.
  final int logNo;
  final DateTime? createdAt;
  final String studentName;
  final String bookName;
  final String problemNumber;
  final int? displayPage;
  final String partKey;
  final String expectedAnswer;
  final String submittedAnswer;
  final String method;
  final List<String> flags;
  final bool deterministicCorrect;
  final bool? aiEquivalent;
  final bool? aiUnitSpecified;
  final bool finalCorrect;
  final String reviewStatus;
  final String teacherVerdict;
  final String reviewNote;
  final DateTime? reviewedAt;

  String get locationLabel {
    final parts = <String>[
      if (bookName.isNotEmpty) bookName,
      if (displayPage != null) 'p.$displayPage',
      if (problemNumber.isNotEmpty) '$problemNumber번',
      if (partKey.isNotEmpty) partKey,
    ];
    return parts.isEmpty ? '교재 문항' : parts.join(' · ');
  }

  static bool? _boolOrNull(dynamic value) {
    if (value is bool) return value;
    return null;
  }

  static _EquivLog fromMap(Map<String, dynamic> map) {
    final displayPage =
        int.tryParse('${map['display_page'] ?? map['raw_page'] ?? ''}');
    return _EquivLog(
      id: '${map['id'] ?? ''}',
      logNo: int.tryParse('${map['log_no'] ?? ''}') ?? 0,
      createdAt: DateTime.tryParse('${map['created_at'] ?? ''}'),
      studentName: '${map['student_name'] ?? '학생'}'.trim(),
      bookName: '${map['book_name'] ?? ''}'.trim(),
      problemNumber: '${map['problem_number'] ?? ''}'.trim(),
      displayPage: displayPage,
      partKey: '${map['part_key'] ?? ''}'.trim(),
      expectedAnswer: '${map['expected_answer'] ?? ''}'.trim(),
      submittedAnswer: '${map['submitted_answer'] ?? ''}'.trim(),
      method: '${map['method'] ?? 'deterministic'}'.trim(),
      flags: map['flags'] is List
          ? (map['flags'] as List)
              .map((e) => '$e'.trim())
              .where((s) => s.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
      deterministicCorrect: map['deterministic_correct'] == true,
      aiEquivalent: _boolOrNull(map['ai_equivalent']),
      aiUnitSpecified: _boolOrNull(map['ai_unit_specified']),
      finalCorrect: map['final_correct'] == true,
      reviewStatus: '${map['review_status'] ?? 'open'}'.trim(),
      teacherVerdict: '${map['teacher_verdict'] ?? ''}'.trim(),
      reviewNote: '${map['review_note'] ?? ''}'.trim(),
      reviewedAt: DateTime.tryParse('${map['reviewed_at'] ?? ''}'),
    );
  }
}
