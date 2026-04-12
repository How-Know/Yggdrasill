import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/data_manager.dart';
import '../services/homework_store.dart';
import '../services/homework_test_grading_result_service.dart';
import '../services/learning_problem_bank_service.dart';
import '../services/tenant_service.dart';
import '../utils/naesin_exam_context.dart';
import 'dialog_tokens.dart';

/// 과제 현황 다이얼로그 하단에 붙는 내신 기출(연도×학교) 그리드.
class HomeworkOverviewNaesinPastExamPanel extends StatefulWidget {
  const HomeworkOverviewNaesinPastExamPanel({
    super.key,
    required this.studentId,
  });

  final String studentId;

  @override
  State<HomeworkOverviewNaesinPastExamPanel> createState() =>
      _HomeworkOverviewNaesinPastExamPanelState();
}

class _OverviewNaesinCellStatus {
  const _OverviewNaesinCellStatus({
    required this.issuedAt,
    required this.firstIssuedAt,
    required this.elapsedMs,
    required this.isEnded,
    required this.isCompleted,
    required this.scoreLabel,
  });

  final DateTime? issuedAt;
  final DateTime? firstIssuedAt;
  final int elapsedMs;
  final bool isEnded;
  final bool isCompleted;
  final String scoreLabel;
}

class _HomeworkOverviewNaesinPastExamPanelState
    extends State<HomeworkOverviewNaesinPastExamPanel> {
  static const String _kTestSourceNaesin = 'naesin';
  static const String _kTestSourceMock = 'mock';
  static const String _kNaesinLinkConfigKey = 'naesinLinkKey';
  static const List<int> _kNaesinYears = <int>[2021, 2022, 2023, 2024, 2025];
  static const double _kPastExamPanelHeight = 288;
  static const double _kNaesinGridSchoolLabelWidth = 120;
  static const double _kNaesinGridCellSize = 58;
  static const double _kNaesinGridCellGap = 12;
  static const double _kNaesinGridLabelToCellsGap = 12;
  static const Color _kNaesinLinkedActiveCellColor = Color(0xFF282828);
  static const List<String> _kNaesinSchools = <String>[
    '경신중',
    '능인중',
    '대륜중',
    '동도중',
    '소선여중',
    '오성중',
    '정화중',
    '황금중',
  ];

  final ScrollController _hScroll = ScrollController();
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  final HomeworkTestGradingResultService _gradingResultService =
      HomeworkTestGradingResultService.instance;

  String _pastExamTab = _kTestSourceNaesin;
  String _naesinGradeKey = '';
  String _naesinCourseKey = '';
  String _naesinExamTerm = '';
  String _naesinStudentSchool = '';
  final Set<String> _linkedKeys = <String>{};
  final Map<String, _OverviewNaesinCellStatus> _statusByLinkKey = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _initNaesinDefaults();
    unawaited(_loadLinkedKeysAndStatus());
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  void _initNaesinDefaults() {
    final now = DateTime.now();
    StudentWithInfo? info;
    for (final row in DataManager.instance.students) {
      if (row.student.id == widget.studentId) {
        info = row;
        break;
      }
    }
    final derived = NaesinExamContext.initialGradeCourseFromStudent(
      info?.student,
      now,
    );
    _naesinGradeKey = derived.gradeKey;
    _naesinCourseKey = derived.courseKey;
    _naesinExamTerm = NaesinExamContext.defaultNaesinExamTermByDate(now);
    _naesinStudentSchool = (info?.student.school ?? '').trim();
  }

  String _linkKeyForCell({required String school, required int year}) {
    return NaesinExamContext.buildNaesinLinkKey(
      gradeKey: _naesinGradeKey,
      courseKey: _naesinCourseKey,
      examTerm: _naesinExamTerm,
      school: school,
      year: year,
    );
  }

  bool _isLinked({required String school, required int year}) {
    if (_naesinGradeKey.isEmpty ||
        _naesinCourseKey.isEmpty ||
        _naesinExamTerm.isEmpty) {
      return false;
    }
    return _linkedKeys.contains(_linkKeyForCell(school: school, year: year));
  }

  DateTime _statusTs(HomeworkItem item) {
    return item.completedAt ??
        item.confirmedAt ??
        item.submittedAt ??
        item.waitingAt ??
        item.updatedAt ??
        item.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _isEnded(HomeworkItem item) {
    return item.phase >= 3 || item.confirmedAt != null;
  }

  int _elapsedMs(HomeworkItem item) {
    final runningMs = item.runStart == null
        ? 0
        : DateTime.now().difference(item.runStart!).inMilliseconds;
    return math.max(0, item.accumulatedMs + runningMs);
  }

  String _fmtElapsed(int elapsedMs) {
    final safeMs = math.max(0, elapsedMs);
    final totalMinutes = safeMs ~/ 60000;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours > 0) {
      return '$hours시간 ${minutes.toString().padLeft(2, '0')}분';
    }
    return '$totalMinutes분';
  }

  String _fmtScore(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.0001) {
      return rounded.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }

  String _fmtIssuedDate(DateTime value) {
    final local = value.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '$mm.$dd';
  }

  String _fmtIssuedDateTime(DateTime value) {
    final local = value.toLocal();
    final yyyy = local.year.toString().padLeft(4, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$yyyy.$mm.$dd $hh:$min';
  }

  Future<Map<String, _OverviewNaesinCellStatus>> _buildStatusMap(
    Set<String> linkedKeys,
  ) async {
    final grouped = <String, List<HomeworkItem>>{};
    final itemIds = <String>{};
    for (final item in HomeworkStore.instance.items(widget.studentId)) {
      if ((item.sourceUnitLevel ?? '').trim().toLowerCase() != 'naesin') {
        continue;
      }
      final linkKey = (item.sourceUnitPath ?? '').trim();
      if (linkKey.isEmpty) continue;
      if (linkedKeys.isNotEmpty && !linkedKeys.contains(linkKey)) continue;
      grouped.putIfAbsent(linkKey, () => <HomeworkItem>[]).add(item);
      final itemId = item.id.trim();
      if (itemId.isNotEmpty) itemIds.add(itemId);
    }
    if (grouped.isEmpty) return const <String, _OverviewNaesinCellStatus>{};
    final latestScoreByItemId =
        await _gradingResultService.loadLatestScoreByHomeworkItemIds(itemIds);
    final out = <String, _OverviewNaesinCellStatus>{};
    grouped.forEach((linkKey, rows) {
      DateTime? firstIssuedAt;
      HomeworkItem? target;
      HomeworkTestLatestScore? latestScore;
      var targetPriority = -1;
      var targetAt = DateTime.fromMillisecondsSinceEpoch(0);
      for (final item in rows) {
        final issuedAt = item.createdAt ?? item.updatedAt;
        if (issuedAt != null &&
            (firstIssuedAt == null || issuedAt.isBefore(firstIssuedAt))) {
          firstIssuedAt = issuedAt;
        }
        final isCompleted = item.status == HomeworkStatus.completed;
        final isEnded = _isEnded(item);
        final priority = isCompleted ? 3 : (isEnded ? 2 : 1);
        final at = _statusTs(item);
        if (target == null ||
            priority > targetPriority ||
            (priority == targetPriority && at.isAfter(targetAt))) {
          target = item;
          targetPriority = priority;
          targetAt = at;
        }
        final score = latestScoreByItemId[item.id.trim()];
        if (score != null &&
            (latestScore == null ||
                score.gradedAt.isAfter(latestScore.gradedAt))) {
          latestScore = score;
        }
      }
      if (target == null) return;
      final isCompleted = target.status == HomeworkStatus.completed;
      final isEnded = !isCompleted && _isEnded(target);
      final scoreLabel = latestScore == null
          ? ''
          : '${_fmtScore(latestScore.scoreCorrect)}/${_fmtScore(latestScore.scoreTotal)}';
      out[linkKey] = _OverviewNaesinCellStatus(
        issuedAt: target.createdAt ?? target.updatedAt,
        firstIssuedAt: firstIssuedAt,
        elapsedMs: _elapsedMs(target),
        isEnded: isEnded,
        isCompleted: isCompleted,
        scoreLabel: scoreLabel,
      );
    });
    return out;
  }

  Future<void> _loadLinkedKeysAndStatus() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      var academyId =
          (await TenantService.instance.getActiveAcademyId() ?? '').trim();
      if (academyId.isEmpty) {
        academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
      }
      if (academyId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _linkedKeys.clear();
          _statusByLinkKey.clear();
        });
        return;
      }
      final presets = await _problemBankService.listExportPresets(
        academyId: academyId,
        limit: 500,
      );
      final linkedKeys = <String>{};
      for (final preset in presets) {
        final key =
            '${preset.renderConfig[_kNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
                .trim();
        if (key.isNotEmpty) linkedKeys.add(key);
      }
      final status = await _buildStatusMap(linkedKeys);
      if (!mounted) return;
      setState(() {
        _linkedKeys
          ..clear()
          ..addAll(linkedKeys);
        _statusByLinkKey
          ..clear()
          ..addAll(status);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linkedKeys.clear();
        _statusByLinkKey.clear();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onCellTap(BuildContext context,
      {required bool linkedActive, required String school, required int year}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!linkedActive) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('문제은행 프리셋에 연결된 내신 셀이 아닙니다.'),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          '과제 추가(+)에서 테스트·내신을 선택한 뒤, 범위 패널 그리드에서 같은 셀을 누르면 과제 초안에 담을 수 있습니다.',
        ),
      ),
    );
  }

  double _gridMinWidth() {
    final n = _kNaesinSchools.length;
    if (n <= 0) {
      return _kNaesinGridSchoolLabelWidth + _kNaesinGridLabelToCellsGap + 40;
    }
    return _kNaesinGridSchoolLabelWidth +
        _kNaesinGridLabelToCellsGap +
        n * _kNaesinGridCellSize +
        (n - 1) * _kNaesinGridCellGap +
        20;
  }

  Widget _pickerChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final borderColor = selected ? kDlgAccent.withOpacity(0.9) : kDlgBorder;
    final bgColor = selected ? const Color(0x1A33A373) : kDlgFieldBg;
    return Opacity(
      opacity: enabled ? 1.0 : 0.52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: borderColor, width: selected ? 1.4 : 1.0),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: enabled
                    ? (selected ? kDlgText : kDlgTextSub)
                    : const Color(0xFF7D8B8B),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 13.8,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noticeCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: kDlgTextSub,
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _statusCell({
    required String school,
    required int year,
    required bool highlightedSchool,
    required bool linkedActive,
    required _OverviewNaesinCellStatus? cellStatus,
  }) {
    final hasIssued = cellStatus?.issuedAt != null;
    final isCompleted = cellStatus?.isCompleted == true;
    final isEnded = (cellStatus?.isEnded == true) || isCompleted;
    final scoreLabel = (cellStatus?.scoreLabel ?? '').trim();
    final hasScore = scoreLabel.isNotEmpty;
    final displayText = () {
      if (isCompleted) return hasScore ? scoreLabel : '완료';
      if (isEnded) return hasScore ? scoreLabel : '종료';
      if (hasIssued) return _fmtIssuedDate(cellStatus!.issuedAt!);
      return '';
    }();
    final borderColor = isCompleted
        ? const Color(0xFF4DBD7A)
        : (linkedActive
            ? _kNaesinLinkedActiveCellColor
            : (highlightedSchool ? kDlgAccent.withOpacity(0.7) : kDlgBorder));
    final fillColor = isCompleted
        ? const Color(0xFF1F4B36)
        : (linkedActive
            ? _kNaesinLinkedActiveCellColor
            : (highlightedSchool
                ? const Color(0x1A33A373)
                : const Color(0xFF151C21)));
    final tooltipLines = <String>['$school · $year'];
    if (cellStatus?.firstIssuedAt != null) {
      tooltipLines.add(
        '처음 내준 시각 ${_fmtIssuedDateTime(cellStatus!.firstIssuedAt!)}',
      );
    }
    if (cellStatus != null) {
      tooltipLines.add('걸린 시간 ${_fmtElapsed(cellStatus.elapsedMs)}');
    }
    if (isCompleted) {
      tooltipLines.add('상태 완료');
    } else if (isEnded) {
      tooltipLines.add('상태 종료');
    }
    if (hasScore) {
      tooltipLines.add('점수 $scoreLabel');
    }
    return Tooltip(
      message: tooltipLines.join('\n'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _onCellTap(
            context,
            linkedActive: linkedActive,
            school: school,
            year: year,
          ),
          child: Container(
            width: _kNaesinGridCellSize,
            height: _kNaesinGridCellSize,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: displayText.isEmpty
                ? null
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          displayText,
                          maxLines: 1,
                          style: TextStyle(
                            color: isCompleted
                                ? const Color(0xFFE4F8EC)
                                : (isEnded ? kDlgText : kDlgTextSub),
                            fontWeight:
                                hasScore ? FontWeight.w800 : FontWeight.w700,
                            fontSize: hasScore ? 12 : 10.8,
                            letterSpacing: hasScore ? 0.2 : 0.1,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        children: [
          const SizedBox(
            width: _kNaesinGridSchoolLabelWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '년도',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: kDlgTextSub,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.2,
                ),
              ),
            ),
          ),
          SizedBox(width: _kNaesinGridLabelToCellsGap),
          for (var i = 0; i < _kNaesinSchools.length; i++) ...[
            SizedBox(
              width: _kNaesinGridCellSize,
              child: Center(
                child: Text(
                  _kNaesinSchools[i],
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                    height: 1.15,
                  ),
                ),
              ),
            ),
            if (i < _kNaesinSchools.length - 1)
              SizedBox(width: _kNaesinGridCellGap),
          ],
        ],
      ),
    );
  }

  Widget _yearRow(int year, String studentSchool) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
      child: Row(
        children: [
          SizedBox(
            width: _kNaesinGridSchoolLabelWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$year',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 13.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SizedBox(width: _kNaesinGridLabelToCellsGap),
          for (var i = 0; i < _kNaesinSchools.length; i++) ...[
            () {
              final school = _kNaesinSchools[i];
              final highlighted =
                  studentSchool.isNotEmpty && studentSchool == school;
              final linkKey = _linkKeyForCell(school: school, year: year);
              final linked = _isLinked(school: school, year: year);
              return _statusCell(
                school: school,
                year: year,
                highlightedSchool: highlighted,
                linkedActive: linked,
                cellStatus: _statusByLinkKey[linkKey],
              );
            }(),
            if (i < _kNaesinSchools.length - 1)
              SizedBox(width: _kNaesinGridCellGap),
          ],
        ],
      ),
    );
  }

  Widget _yearSchoolGrid() {
    final studentSchool = _naesinStudentSchool;
    return Scrollbar(
      controller: _hScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _hScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _gridMinWidth(),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _headerRow(),
                const Divider(height: 1, thickness: 1, color: kDlgBorder),
                if (_loading)
                  const LinearProgressIndicator(
                    minHeight: 1.2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final year in _kNaesinYears)
                        _yearRow(year, studentSchool),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kPastExamPanelHeight,
      width: double.infinity,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(
              icon: Icons.history_edu_outlined,
              title: '기출',
            ),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                _pickerChip(
                  label: '내신',
                  selected: _pastExamTab == _kTestSourceNaesin,
                  onTap: () {
                    if (_pastExamTab == _kTestSourceNaesin) return;
                    setState(() => _pastExamTab = _kTestSourceNaesin);
                  },
                ),
                _pickerChip(
                  label: '모의고사',
                  selected: _pastExamTab == _kTestSourceMock,
                  onTap: () {
                    if (_pastExamTab == _kTestSourceMock) return;
                    setState(() => _pastExamTab = _kTestSourceMock);
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(
                        content: Text('모의고사 기출은 다음 단계에서 구현됩니다.'),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '모의고사 기출은 다음 단계에서 구현됩니다.',
              style: TextStyle(
                color: kDlgTextSub,
                fontSize: 11.6,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _pastExamTab != _kTestSourceNaesin
                  ? Center(
                      child: _noticeCard('모의고사 기출을 준비 중입니다.'),
                    )
                  : _yearSchoolGrid(),
            ),
          ],
        ),
      ),
    );
  }
}
