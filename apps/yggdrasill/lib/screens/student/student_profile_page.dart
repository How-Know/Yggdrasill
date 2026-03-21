import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../models/education_level.dart';
import '../../models/student_flow.dart';
import '../../widgets/pill_tab_selector.dart';
import '../../models/attendance_record.dart';
import '../../services/homework_store.dart';
import '../../services/homework_assignment_store.dart';
import '../../services/tag_store.dart';
import '../../services/student_flow_store.dart';
import '../../services/student_behavior_assignment_store.dart';
import '../../services/learning_behavior_card_service.dart';
import '../../services/tag_preset_service.dart';
import '../../screens/learning/tag_preset_dialog.dart';
import '../../widgets/swipe_action_reveal.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/latex_text_renderer.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class StudentProfilePage extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final List<StudentFlow>? flows;

  const StudentProfilePage({
    super.key,
    required this.studentWithInfo,
    this.flows = const [],
  });

  @override
  State<StudentProfilePage> createState() => _StudentProfilePageState();
}

class _StudentProfilePageState extends State<StudentProfilePage> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    // ClassStatusScreen과 동일한 구조 적용
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0), // 왼쪽 여백 (AllStudentsView와 일치)
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  constraints: const BoxConstraints(
                    minWidth: 624,
                  ),
                  padding: const EdgeInsets.only(left: 34, right: 24, top: 24, bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      // 헤더 영역
                      _StudentProfileHeader(
                        studentWithInfo: widget.studentWithInfo,
                        tabIndex: _tabIndex,
                        onTabChanged: (next) => setState(() => _tabIndex = next),
                      ),
                      const SizedBox(height: 24),
                      // 메인 콘텐츠 영역
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B1112),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _StudentProfileContent(
                            tabIndex: _tabIndex,
                            studentWithInfo: widget.studentWithInfo,
                            flows: widget.flows,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentProfileHeader extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  const _StudentProfileHeader({
    required this.studentWithInfo,
    required this.tabIndex,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final basicInfo = studentWithInfo.basicInfo;
    final String levelName = getEducationLevelName(student.educationLevel);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    // 뒤로가기 버튼
                    Container(
                      width: 40,
                      height: 40,
                      margin: const EdgeInsets.only(right: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: '뒤로',
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: student.groupInfo?.color ?? const Color(0xFF2C3A3A),
                      child: Text(
                        student.name.characters.take(1).toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      student.name,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 15),
                    Flexible(
                      child: Text(
                        '$levelName · ${student.grade}학년 · ${student.school}',
                        style: const TextStyle(
                          color: Color(0xFFCBD8D8),
                          fontSize: 18,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              PillTabSelector(
                width: 300,
                height: 40,
                fontSize: 15,
                selectedIndex: tabIndex,
            tabs: const ['요약', '수업 일지', '스탯'],
                onTabSelected: onTabChanged,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '등록일 ${DateFormat('yyyy.MM.dd').format(basicInfo.registrationDate ?? DateTime.now())}',
                    style: const TextStyle(
                      color: Color(0xFFCBD8D8),
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF223131), height: 1, thickness: 1),
        ],
      ),
    );
  }
}

class _StudentProfileContent extends StatelessWidget {
  final int tabIndex;
  final StudentWithInfo studentWithInfo;
  final List<StudentFlow>? flows;
  const _StudentProfileContent({
    required this.tabIndex,
    required this.studentWithInfo,
    required this.flows,
  });

  @override
  Widget build(BuildContext context) {
    if (tabIndex == 1) {
      final safeFlows = flows ?? const <StudentFlow>[];
      return _StudentTimelineView(
        studentWithInfo: studentWithInfo,
        flows: safeFlows,
      );
    }
    if (tabIndex == 2) {
      return _StudentStatsView(studentWithInfo: studentWithInfo);
    }
    final String label = tabIndex == 0 ? '요약 준비 중입니다.' : '스탯 준비 중입니다.';
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withOpacity(0.3),
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _StudentStatsView extends StatefulWidget {
  final StudentWithInfo studentWithInfo;

  const _StudentStatsView({required this.studentWithInfo});

  @override
  State<_StudentStatsView> createState() => _StudentStatsViewState();
}

class _StudentStatsViewState extends State<_StudentStatsView> {
  bool _loading = true;
  bool _saving = false;
  String? _errorText;
  List<_LevelOption> _options = const <_LevelOption>[];
  int? _currentLevelCode;
  int? _desiredLevelCode;
  int? _targetLevelCode;
  late Future<Map<String, dynamic>> _homeworkScoreFuture;

  @override
  void initState() {
    super.initState();
    _homeworkScoreFuture = _buildHomeworkScoreFuture();
    HomeworkStore.instance.revision.addListener(_onHomeworkSignalsChanged);
    HomeworkAssignmentStore.instance.revision.addListener(_onHomeworkSignalsChanged);
    DataManager.instance.studentsNotifier.addListener(_onHomeworkSignalsChanged);
    unawaited(HomeworkStore.instance.loadAll());
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _StudentStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prevId = oldWidget.studentWithInfo.student.id.trim();
    final nextId = widget.studentWithInfo.student.id.trim();
    if (prevId != nextId) {
      _refreshHomeworkScoreFuture();
    }
  }

  @override
  void dispose() {
    HomeworkStore.instance.revision.removeListener(_onHomeworkSignalsChanged);
    HomeworkAssignmentStore.instance.revision.removeListener(_onHomeworkSignalsChanged);
    DataManager.instance.studentsNotifier.removeListener(_onHomeworkSignalsChanged);
    super.dispose();
  }

  Future<Map<String, dynamic>> _buildHomeworkScoreFuture() {
    return DataManager.instance.calculateHomeworkScoreWithRankAsync(
      studentId: widget.studentWithInfo.student.id,
    );
  }

  void _refreshHomeworkScoreFuture() {
    if (!mounted) return;
    setState(() {
      _homeworkScoreFuture = _buildHomeworkScoreFuture();
    });
  }

  void _onHomeworkSignalsChanged() {
    _refreshHomeworkScoreFuture();
  }

  List<_LevelOption> _fallbackOptions() {
    return const <_LevelOption>[
      _LevelOption(1, '1등급'),
      _LevelOption(2, '2등급'),
      _LevelOption(3, '3등급'),
      _LevelOption(4, '4등급'),
      _LevelOption(5, '5등급'),
      _LevelOption(6, '6등급'),
    ];
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final rows = await DataManager.instance.loadStudentLevelScales();
      final parsed = rows
          .map((row) {
            final code = _asInt(row['level_code']);
            if (code == null || code < 1 || code > 6) return null;
            final label = (row['display_name'] as String?)?.trim();
            return _LevelOption(
              code,
              (label == null || label.isEmpty) ? '${code}등급' : label,
            );
          })
          .whereType<_LevelOption>()
          .toList()
        ..sort((a, b) => a.code.compareTo(b.code));

      final state = await DataManager.instance.loadStudentLevelState(
        widget.studentWithInfo.student.id,
      );
      if (!mounted) return;
      setState(() {
        _options = parsed.isNotEmpty ? parsed : _fallbackOptions();
        _currentLevelCode = _asInt(state?['current_level_code']);
        _desiredLevelCode = _asInt(state?['desired_level_code']);
        _targetLevelCode = _asInt(state?['target_level_code']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _options = _fallbackOptions();
        _loading = false;
        _errorText = '레벨 정보를 불러오지 못했어요: $e';
      });
    }
  }

  String _labelForCode(int? code) {
    if (code == null) return '미설정';
    final match = _options.where((o) => o.code == code);
    if (match.isNotEmpty) return match.first.label;
    return '${code}등급';
  }

  List<DropdownMenuItem<int?>> _buildLevelItems() {
    return <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(
        value: null,
        child: Text('미설정'),
      ),
      ..._options.map(
        (o) => DropdownMenuItem<int?>(
          value: o.code,
          child: Text(o.label),
        ),
      ),
    ];
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: kDlgTextSub),
      filled: true,
      fillColor: const Color(0xFF15171C),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgAccent),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      final studentId = widget.studentWithInfo.student.id;
      await DataManager.instance.saveStudentLevelState(
        studentId: studentId,
        currentLevelCode: _currentLevelCode,
        desiredLevelCode: _desiredLevelCode,
        targetLevelCode: _targetLevelCode,
      );
      final readBack = await DataManager.instance.loadStudentLevelState(studentId);
      final rbCurrent = _asInt(readBack?['current_level_code']);
      final rbDesired = _asInt(readBack?['desired_level_code']);
      final rbTarget = _asInt(readBack?['target_level_code']);
      final bool verified = rbCurrent == _currentLevelCode &&
          rbDesired == _desiredLevelCode &&
          rbTarget == _targetLevelCode;
      final bool serverReadback = TagPresetService.preferSupabaseRead;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            verified
                ? (serverReadback
                    ? '학생 등급(현재/희망/예상)을 저장했고 서버 반영까지 확인했어요.'
                    : '학생 등급(현재/희망/예상)을 저장했고 재조회로 확인했어요.')
                : (serverReadback
                    ? '학생 등급은 저장했지만 서버 확인값이 달라요. 다시 불러와 확인해 주세요.'
                    : '학생 등급은 저장했지만 확인값이 달라요. 다시 불러와 확인해 주세요.'),
          ),
        ),
      );
      setState(() {
        _currentLevelCode = rbCurrent;
        _desiredLevelCode = rbDesired;
        _targetLevelCode = rbTarget;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = '저장에 실패했어요: $e';
      });
    }
  }

  Widget _metricChip({
    required String label,
    required double value,
    required double ratio,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        '$label ${ratio.toStringAsFixed(1)}% (${value.toStringAsFixed(2)})',
        style: const TextStyle(
          color: kDlgText,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildAttendanceScoreCard(Map<String, dynamic> scoreMap) {
    final totalWeight = _asDouble(scoreMap['totalWeight']);
    final pendingIgnored = _asInt(scoreMap['pendingIgnoredCount']) ?? 0;
    if (totalWeight <= 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF15171C),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Text(
          '출석 점수를 계산할 기록이 아직 충분하지 않아요. 출석/지각/결석 이벤트가 누적되면 점수가 표시됩니다.',
          style: TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.4),
        ),
      );
    }

    final score100 = _asDouble(scoreMap['score100']);
    final weightedPresent = _asDouble(scoreMap['weightedPresent']);
    final weightedLate = _asDouble(scoreMap['weightedLate']);
    final weightedAbsent = _asDouble(scoreMap['weightedAbsent']);
    final eventCount = _asInt(scoreMap['eventCount']) ?? 0;
    final halfLifeDays = _asDouble(scoreMap['halfLifeDays']);
    final priorRatio = _asDouble(scoreMap['priorRatio']);
    final smoothingK = _asDouble(scoreMap['smoothingK']);
    final thresholdMinutes = _asInt(scoreMap['latenessThresholdMinutes']) ?? 10;
    final makeupCountThisMonth = _asInt(scoreMap['makeupCountThisMonth']) ?? 0;
    final monthClassCount = _asInt(scoreMap['monthClassCount']) ?? 0;
    final makeupRatioThisMonth = _asDouble(scoreMap['makeupRatioThisMonth']);
    final makeupPenalty = _asDouble(scoreMap['makeupPenalty']);
    final score100BeforeMakeup = _asDouble(scoreMap['score100BeforeMakeup']);
    final score100AfterMakeup = _asDouble(scoreMap['score100AfterMakeup']);
    final rank = _asInt(scoreMap['rank']);
    final cohortSize = _asInt(scoreMap['cohortSize']) ?? 0;
    final topPercent = _asDouble(scoreMap['topPercent']);

    final double presentRatio =
        totalWeight > 0 ? (weightedPresent / totalWeight) * 100.0 : 0.0;
    final double lateRatio =
        totalWeight > 0 ? (weightedLate / totalWeight) * 100.0 : 0.0;
    final double absentRatio =
        totalWeight > 0 ? (weightedAbsent / totalWeight) * 100.0 : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '출석 점수',
                      style: TextStyle(
                        color: kDlgText,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '최근 기록일수록 더 크게 반영되고, 수업량/재원기간 편향을 비율+스무딩으로 완화합니다.',
                      style: TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.35),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D473A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2B7D67)),
                ),
                child: Text(
                  '${score100.toStringAsFixed(1)}점',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricChip(
                label: '출석',
                value: weightedPresent,
                ratio: presentRatio,
                color: const Color(0xFF33A373),
              ),
              _metricChip(
                label: '지각',
                value: weightedLate,
                ratio: lateRatio,
                color: const Color(0xFFE09C3D),
              ),
              _metricChip(
                label: '결석',
                value: weightedAbsent,
                ratio: absentRatio,
                color: const Color(0xFFD95C5C),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '기준: 반감기 ${halfLifeDays.toStringAsFixed(0)}일 · prior ${(priorRatio * 100).toStringAsFixed(0)}점 · k=${smoothingK.toStringAsFixed(0)} · 지각 기준 ${thresholdMinutes}분',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '반영 이벤트 ${eventCount}건 · 미반영 예정 ${pendingIgnored}건',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            '보강: 이번달 ${makeupCountThisMonth}회 / 월수업 ${monthClassCount}회 (${(makeupRatioThisMonth * 100).toStringAsFixed(1)}%)',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          Text(
            '보강 반영: ${score100BeforeMakeup.toStringAsFixed(1)}점 -> ${score100AfterMakeup.toStringAsFixed(1)}점 (감점 ${(makeupPenalty * 100).toStringAsFixed(1)}점)',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            (rank != null && cohortSize > 0)
                ? '재원생 기준 ${rank}등 / ${cohortSize}명 (상위 ${topPercent.toStringAsFixed(1)}%)'
                : '재원생 순위 계산을 위한 데이터가 부족해요.',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeworkScoreLoadingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: kDlgAccent,
            ),
          ),
          SizedBox(width: 10),
          Text(
            '과제 점수를 계산하는 중입니다...',
            style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeworkScoreErrorCard(Object? error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Text(
        '과제 점수 계산 중 오류가 발생했어요: $error',
        style: const TextStyle(color: Color(0xFFEF6A6A), fontSize: 12.5, height: 1.35),
      ),
    );
  }

  Widget _buildHomeworkScoreCard(Map<String, dynamic> scoreMap) {
    final score100 = _asDouble(scoreMap['score100']);
    final expRaw = _asDouble(scoreMap['expRaw']);
    final expDecayed = _asDouble(scoreMap['expDecayed']);
    final assignedExpDecayed = _asDouble(scoreMap['assignedExpDecayed']);
    final checkExpDecayed = _asDouble(scoreMap['checkExpDecayed']);
    final completedExpDecayed = _asDouble(scoreMap['completedExpDecayed']);
    final eventCount = _asInt(scoreMap['eventCount']) ?? 0;
    final assignedCount = _asInt(scoreMap['assignedCount']) ?? 0;
    final checkCount = _asInt(scoreMap['checkCount']) ?? 0;
    final completedCount = _asInt(scoreMap['completedCount']) ?? 0;
    final halfLifeDays = _asDouble(scoreMap['halfLifeDays']);
    final scaleK = _asDouble(scoreMap['scaleK']);
    final formulaVersion = (scoreMap['formulaVersion'] as String?)?.trim();
    final rank = _asInt(scoreMap['rank']);
    final cohortSize = _asInt(scoreMap['cohortSize']) ?? 0;
    final topPercent = _asDouble(scoreMap['topPercent']);
    final rawLastEventAt = (scoreMap['lastEventAt'] as String?)?.trim();
    DateTime? lastEventAt;
    if (rawLastEventAt != null && rawLastEventAt.isNotEmpty) {
      lastEventAt = DateTime.tryParse(rawLastEventAt)?.toLocal();
    }
    final String lastEventText =
        lastEventAt == null ? '없음' : DateFormat('yyyy.MM.dd').format(lastEventAt);

    if (eventCount <= 0 || expDecayed <= 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF15171C),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Text(
          '과제 점수를 계산할 기록이 아직 충분하지 않아요. 과제 배정/검사/완료 기록이 누적되면 점수가 표시됩니다.',
          style: TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.4),
        ),
      );
    }

    final double totalExp = expDecayed;
    final double completedRatio =
        totalExp > 0 ? (completedExpDecayed / totalExp) * 100.0 : 0.0;
    final double checkRatio =
        totalExp > 0 ? (checkExpDecayed / totalExp) * 100.0 : 0.0;
    final double assignedRatio =
        totalExp > 0 ? (assignedExpDecayed / totalExp) * 100.0 : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '과제 점수 (EXP)',
                      style: TextStyle(
                        color: kDlgText,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '배정/검사/완료 이벤트를 누적하고, 오래된 기록은 약하게만 희석해 장기 성실도를 반영합니다.',
                      style: TextStyle(color: kDlgTextSub, fontSize: 12.5, height: 1.35),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3E63),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF35679E)),
                ),
                child: Text(
                  '${score100.toStringAsFixed(1)}점',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricChip(
                label: '완료',
                value: completedExpDecayed,
                ratio: completedRatio,
                color: const Color(0xFF33A373),
              ),
              _metricChip(
                label: '검사',
                value: checkExpDecayed,
                ratio: checkRatio,
                color: const Color(0xFFE09C3D),
              ),
              _metricChip(
                label: '배정',
                value: assignedExpDecayed,
                ratio: assignedRatio,
                color: const Color(0xFF5A8DEE),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '누적 EXP ${expRaw.toStringAsFixed(1)} · 희석 반영 EXP ${expDecayed.toStringAsFixed(1)}',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '반영 이벤트 ${eventCount}건 (완료 ${completedCount} · 검사 ${checkCount} · 배정 ${assignedCount}) · 마지막 반영 ${lastEventText}',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '기준: 반감기 ${halfLifeDays.toStringAsFixed(0)}일 · scaleK ${scaleK.toStringAsFixed(0)} · ${formulaVersion ?? 'homework_score_v1'}',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            (rank != null && cohortSize > 0)
                ? '재원생 기준 ${rank}등 / ${cohortSize}명 (상위 ${topPercent.toStringAsFixed(1)}%)'
                : '재원생 순위 계산을 위한 데이터가 부족해요.',
            style: const TextStyle(color: kDlgTextSub, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kDlgAccent),
      );
    }

    return ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (_, __, ___) {
        return ValueListenableBuilder<List<StudentWithInfo>>(
          valueListenable: DataManager.instance.studentsNotifier,
          builder: (_, ____, _____) {
            final scoreMap = DataManager.instance.calculateAttendanceScoreWithRank(
              studentId: widget.studentWithInfo.student.id,
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double panelWidth = constraints.maxWidth * 0.5;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: panelWidth,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                        decoration: BoxDecoration(
                          color: kDlgPanelBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: kDlgBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                    Text(
                      '등급(레벨) 입력',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: kDlgText,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '현재/희망/예상 등급은 수동으로 저장하며, 과제 완료 시점 스냅샷에 사용됩니다.',
                      style: TextStyle(color: kDlgTextSub, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            value: _currentLevelCode,
                            items: _buildLevelItems(),
                            decoration: _inputDecoration('현재 등급'),
                            style: const TextStyle(color: kDlgText),
                            dropdownColor: const Color(0xFF15171C),
                            onChanged: (value) =>
                                setState(() => _currentLevelCode = value),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            value: _desiredLevelCode,
                            items: _buildLevelItems(),
                            decoration: _inputDecoration('희망 등급'),
                            style: const TextStyle(color: kDlgText),
                            dropdownColor: const Color(0xFF15171C),
                            onChanged: (value) =>
                                setState(() => _desiredLevelCode = value),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      value: _targetLevelCode,
                      items: _buildLevelItems(),
                      decoration: _inputDecoration('예상 등급'),
                      style: const TextStyle(color: kDlgText),
                      dropdownColor: const Color(0xFF15171C),
                      onChanged: (value) =>
                          setState(() => _targetLevelCode = value),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '현재: ${_labelForCode(_currentLevelCode)}   ·   희망: ${_labelForCode(_desiredLevelCode)}   ·   예상: ${_labelForCode(_targetLevelCode)}',
                      style: const TextStyle(color: kDlgTextSub, fontSize: 12),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _errorText!,
                        style: const TextStyle(color: Color(0xFFEF6A6A), fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _saving ? null : () => unawaited(_load()),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: kDlgTextSub,
                            side: const BorderSide(color: kDlgBorder),
                          ),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('다시 불러오기'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(
                            backgroundColor: kDlgAccent,
                            foregroundColor: Colors.white,
                          ),
                          icon: _saving
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save, size: 16),
                          label: Text(_saving ? '저장 중...' : '저장'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Divider(color: kDlgBorder),
                    const SizedBox(height: 10),
                    const YggDialogSectionHeader(
                      icon: Icons.shield_outlined,
                      title: '비개입 변수',
                    ),
                    const Text(
                      '통제 어려운 변수를 별도 축으로 관리합니다. (마음/재능/운/학습 환경)',
                      style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15171C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: const Text(
                        '이번 단계에서는 비개입 변수 세부 지표를 준비 중입니다.',
                        style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const YggDialogSectionHeader(
                      icon: Icons.tune,
                      title: '개입 가능 변수',
                    ),
                    const Text(
                      '의도적 훈련/설계로 바꿀 수 있는 변수입니다. 현재는 출석 점수와 과제 점수를 1단계로 반영합니다.',
                      style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    _buildAttendanceScoreCard(scoreMap),
                    const SizedBox(height: 12),
                    FutureBuilder<Map<String, dynamic>>(
                      future: _homeworkScoreFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return _buildHomeworkScoreLoadingCard();
                        }
                        if (snapshot.hasError) {
                          return _buildHomeworkScoreErrorCard(snapshot.error);
                        }
                        return _buildHomeworkScoreCard(
                          snapshot.data ?? const <String, dynamic>{},
                        );
                      },
                    ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _LevelOption {
  final int code;
  final String label;

  const _LevelOption(this.code, this.label);
}

class _StudentTimelineView extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final List<StudentFlow>? flows;
  const _StudentTimelineView({
    required this.studentWithInfo,
    required this.flows,
  });

  @override
  State<_StudentTimelineView> createState() => _StudentTimelineViewState();
}

class _StudentTimelineViewState extends State<_StudentTimelineView> {
  final ScrollController _timelineScrollController = ScrollController();
  static const Color _attendanceColor = Color(0xFF33A373);
  static const Color _recordColor = Color(0xFF9AA0A6);
  DateTime _anchorDate = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  int _daysLoaded = 31;
  bool _showAttendance = true;
  bool _showTags = true;

  @override
  void initState() {
    super.initState();
    _timelineScrollController.addListener(_handleScroll);
    unawaited(TagStore.instance.loadAllFromDb());
    unawaited(HomeworkStore.instance.loadAll());
    unawaited(
      StudentBehaviorAssignmentStore.instance
          .loadForStudent(widget.studentWithInfo.student.id),
    );
  }

  @override
  void dispose() {
    _timelineScrollController.removeListener(_handleScroll);
    _timelineScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (_, __, ___) {
        return ValueListenableBuilder<int>(
          valueListenable: TagStore.instance.revision,
          builder: (_, ____, _____) {
            final entries = _collectTimelineEntries(
              widget.studentWithInfo,
              _anchorDate,
              _daysLoaded,
            );
            final items = _buildRenderableTimeline(entries);
            final enabledFlows =
                (widget.flows ?? const <StudentFlow>[])
                    .where((f) => f.enabled)
                    .toList();
            const double timelineMaxWidth = 860 * 0.56;
            const double flowCardWidth = timelineMaxWidth;
            const double flowCardSpacing = 16;
            const double behaviorCardWidth = timelineMaxWidth;
            final int flowCount = enabledFlows.length;
            final double flowSidebarWidth = flowCount == 0
                ? 0
                : (flowCardWidth * flowCount) +
                    (flowCardSpacing * (flowCount - 1));
            final timelineCard = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: timelineMaxWidth),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF10171A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF223131)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _filterChip(
                          label: '등/하원',
                          selected: _showAttendance,
                          onSelected: (v) =>
                              setState(() => _showAttendance = v),
                        ),
                        const SizedBox(width: 8),
                        _filterChip(
                          label: '태그',
                          selected: _showTags,
                          onSelected: (v) => setState(() => _showTags = v),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF151C21),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0xFF223131)),
                          ),
                          child: Text(
                            DateFormat('yyyy.MM.dd').format(_anchorDate),
                            style: const TextStyle(
                              color: Color(0xFF9FB3B3),
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildTimelineHeaderActionButton(
                          tooltip: '날짜 선택',
                          icon: Icons.event,
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _anchorDate,
                              firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                              builder: (context, child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: const ColorScheme.dark(primary: Color(0xFF1B6B63)),
                                    dialogBackgroundColor: const Color(0xFF0B1112),
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            if (picked != null) {
                              setState(() {
                                _anchorDate = DateTime(picked.year, picked.month, picked.day);
                                _daysLoaded = 31;
                              });
                              if (_timelineScrollController.hasClients) {
                                _timelineScrollController.jumpTo(0);
                              }
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        _buildTimelineHeaderActionButton(
                          tooltip: '태그 관리',
                          icon: Icons.style,
                          onPressed: () async {
                            await showDialog(
                              context: context,
                              builder: (_) => const TagPresetDialog(),
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(color: Color(0xFF223131), height: 1),
                    const SizedBox(height: 12),
                    Expanded(
                      child: items.isEmpty
                          ? const Center(child: Text('기록이 없습니다.', style: TextStyle(color: Colors.white54)))
                          : ListView.separated(
                              controller: _timelineScrollController,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: items.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final item = items[index];
                                if (item is _TimelineHeader) {
                                  return _buildDateHeader(item.date);
                                } else if (item is _TimelineEntry) {
                                  return _buildTimelineEntry(item);
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
            return Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: timelineMaxWidth, child: timelineCard),
                    const SizedBox(width: flowCardSpacing),
                    SizedBox(
                      width: behaviorCardWidth,
                      child: _BehaviorAssignmentSidebar(
                        studentId: widget.studentWithInfo.student.id,
                        cardWidth: behaviorCardWidth,
                      ),
                    ),
                    if (enabledFlows.isNotEmpty) ...[
                      const SizedBox(width: flowCardSpacing),
                      SizedBox(
                        width: flowSidebarWidth,
                        child: _FlowHomeworkSidebar(
                          studentId: widget.studentWithInfo.student.id,
                          flows: enabledFlows,
                          cardWidth: flowCardWidth,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return InkWell(
      onTap: () => onSelected(!selected),
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1C2A2D) : const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color:
                selected ? const Color(0xFF2A6D62) : const Color(0xFF223131),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color:
                selected ? const Color(0xFFD6ECEA) : const Color(0xFF9FB3B3),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineHeaderActionButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: const Color(0xFF9FB3B3), size: 18),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF151C21),
          side: const BorderSide(color: Color(0xFF223131)),
        ),
      ),
    );
  }

  Widget _buildDateHeader(DateTime date) {
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFF223131))),
        const SizedBox(width: 8),
        Text(
          DateFormat('yyyy.MM.dd').format(date),
          style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: Color(0xFF223131))),
      ],
    );
  }

  Widget _buildTimelineEntry(_TimelineEntry entry) {
    final timeText = DateFormat('HH:mm').format(entry.time);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(entry.icon, color: entry.color, size: 18),
              const SizedBox(width: 8),
              Text(
                entry.label,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
              ),
              if (entry.isTag) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1518),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  child: const Text('태그', style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
          if (entry.note != null && entry.note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(entry.note!, style: const TextStyle(color: Colors.white60, fontSize: 13)),
            ),
        ],
      ),
    );

    final wrappedCard = entry.isTag && entry.setId != null && entry.studentId != null
        ? _wrapSwipeActions(
            child: card,
            onEdit: () => _editTimelineEntry(entry),
            onDelete: () => _deleteTimelineEntry(entry),
          )
        : card;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              timeText,
              style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: entry.color.withOpacity(0.18),
                  border: Border.all(color: entry.color, width: 1.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(width: 2, color: const Color(0xFF223131)),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(child: wrappedCard),
        ],
      ),
    );
  }

  List<_TimelineEntry> _collectTimelineEntries(StudentWithInfo student, DateTime anchor, int days) {
    final List<_TimelineEntry> all = [];
    final DateTime normalizedAnchor = DateTime(anchor.year, anchor.month, anchor.day);
    final records = DataManager.instance.getAttendanceRecordsForStudent(student.student.id);
    for (int i = 0; i < days; i++) {
      final dayStart = normalizedAnchor.subtract(Duration(days: i));
      final dayEnd = dayStart.add(const Duration(days: 1));
      all.addAll(_collectEntriesForRange(student, dayStart, dayEnd, records));
    }
    all.sort((a, b) => b.time.compareTo(a.time));
    return all;
  }

  List<_TimelineEntry> _collectEntriesForRange(
    StudentWithInfo student,
    DateTime start,
    DateTime end,
    List<AttendanceRecord> records,
  ) {
    final entries = <_TimelineEntry>[];
    final seen = <String>{};
    final studentId = student.student.id;

    if (_showAttendance) {
      for (final record in records) {
        final arrival = record.arrivalTime?.toLocal();
        final departure = record.departureTime?.toLocal();
        if (arrival != null && !arrival.isBefore(start) && arrival.isBefore(end)) {
          final key = 'arr_${arrival.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_TimelineEntry(
              time: arrival,
              icon: Icons.login,
              color: _attendanceColor,
              label: '등원',
              isTag: false,
            ));
          }
        }
        if (departure != null && !departure.isBefore(start) && departure.isBefore(end)) {
          final key = 'dep_${departure.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_TimelineEntry(
              time: departure,
              icon: Icons.logout,
              color: _attendanceColor,
              label: '하원',
              isTag: false,
            ));
          }
        }
      }
    }

    if (_showTags) {
      final dayIndex = start.weekday - 1;
      final blocks = DataManager.instance.studentTimeBlocks.where(
        (block) => block.studentId == studentId && block.setId != null && block.dayIndex == dayIndex,
      );
      for (final block in blocks) {
        final events = TagStore.instance.getEventsForSet(block.setId!);
        for (final event in events) {
          final ts = event.timestamp.toLocal();
          if (ts.isAfter(start) && ts.isBefore(end)) {
            final key = 'tag_${block.setId}_${event.tagName}_${ts.millisecondsSinceEpoch}_${event.note ?? ''}';
            if (seen.add(key)) {
              final bool isRecord = event.tagName.trim() == '기록';
              entries.add(_TimelineEntry(
                time: ts,
                icon: IconData(event.iconCodePoint, fontFamily: 'MaterialIcons'),
                color: isRecord ? _recordColor : Color(event.colorValue),
                label: event.tagName,
                note: event.note,
                isTag: true,
                setId: block.setId,
                studentId: studentId,
                rawColorValue: event.colorValue,
                rawIconCodePoint: event.iconCodePoint,
              ));
            }
          }
        }
      }
    }

    return entries;
  }

  List<dynamic> _buildRenderableTimeline(List<_TimelineEntry> entries) {
    final List<dynamic> list = [];
    DateTime? currentDate;
    for (final entry in entries) {
      final date = DateTime(entry.time.year, entry.time.month, entry.time.day);
      if (currentDate == null || currentDate.millisecondsSinceEpoch != date.millisecondsSinceEpoch) {
        currentDate = date;
        list.add(_TimelineHeader(date: date));
      }
      list.add(entry);
    }
    return list;
  }

  void _handleScroll() {
    if (!_timelineScrollController.hasClients) return;
    if (_timelineScrollController.position.pixels >= _timelineScrollController.position.maxScrollExtent - 80) {
      setState(() {
        _daysLoaded += 31;
      });
    }
  }

  Widget _wrapSwipeActions({
    required Widget child,
    required Future<void> Function() onEdit,
    required Future<void> Function() onDelete,
  }) {
    const double paneW = 140;
    final radius = BorderRadius.circular(12);
    final actionPane = Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: const Color(0xFF223131),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () async => onEdit(),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.06),
                hoverColor: Colors.white.withOpacity(0.03),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: const Color(0xFFB74C4C),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () async => onDelete(),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.08),
                hoverColor: Colors.white.withOpacity(0.04),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return SwipeActionReveal(
      enabled: true,
      actionPaneWidth: paneW,
      borderRadius: radius,
      actionPane: actionPane,
      child: child,
    );
  }

  Future<void> _editTimelineEntry(_TimelineEntry entry) async {
    if (entry.setId == null || entry.studentId == null) return;
    final title = entry.label.trim() == '기록' ? '기록 수정' : '태그 메모 수정';
    final edited = await _openTimelineNoteDialog(
      title: title,
      initial: entry.note ?? '',
    );
    if (edited == null) return;
    final trimmed = edited.trim();
    final updated = TagEvent(
      tagName: entry.label,
      colorValue: entry.rawColorValue ?? entry.color.value,
      iconCodePoint: entry.rawIconCodePoint ?? entry.icon.codePoint,
      timestamp: entry.time,
      note: trimmed.isEmpty ? null : trimmed,
    );
    TagStore.instance.updateEvent(entry.setId!, entry.studentId!, updated);
  }

  Future<void> _deleteTimelineEntry(_TimelineEntry entry) async {
    if (entry.setId == null || entry.studentId == null) return;
    final ok = await _confirmDeleteTimelineEntry(entry.label);
    if (ok != true) return;
    final target = TagEvent(
      tagName: entry.label,
      colorValue: entry.rawColorValue ?? entry.color.value,
      iconCodePoint: entry.rawIconCodePoint ?? entry.icon.codePoint,
      timestamp: entry.time,
      note: entry.note,
    );
    TagStore.instance.deleteEvent(entry.setId!, entry.studentId!, target);
  }

  Future<bool?> _confirmDeleteTimelineEntry(String label) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kDlgBorder),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        title: const Text('기록 삭제', style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900)),
        content: Text(
          '“$label” 기록을 삭제할까요?',
          style: const TextStyle(color: kDlgTextSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB74C4C)),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<String?> _openTimelineNoteDialog({
    required String title,
    required String initial,
  }) async {
    final controller = ImeAwareTextEditingController(text: initial);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kDlgBorder),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        title: Text(title, style: const TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: '메모를 입력하세요',
              hintStyle: const TextStyle(color: kDlgTextSub),
              filled: true,
              fillColor: kDlgFieldBg,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: kDlgBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: kDlgAccent),
              ),
            ),
            style: const TextStyle(color: kDlgText),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              FocusScope.of(ctx).unfocus();
              controller.value = controller.value.copyWith(composing: TextRange.empty);
              Navigator.of(ctx).pop(controller.text);
            },
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
            child: const Text('저장', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    return result;
  }
}

class _HomeworkStats {
  final int inProgress;
  final int homework;
  final int completed;
  const _HomeworkStats({
    required this.inProgress,
    required this.homework,
    required this.completed,
  });

  factory _HomeworkStats.fromItems(List<HomeworkItem> items) {
    int inProgress = 0;
    int homework = 0;
    int completed = 0;
    for (final item in items) {
      switch (item.status) {
        case HomeworkStatus.inProgress:
          inProgress += 1;
          break;
        case HomeworkStatus.homework:
          homework += 1;
          break;
        case HomeworkStatus.completed:
          completed += 1;
          break;
      }
    }
    return _HomeworkStats(
      inProgress: inProgress,
      homework: homework,
      completed: completed,
    );
  }
}

class _FlowHomeworkSidebar extends StatefulWidget {
  final String studentId;
  final List<StudentFlow> flows;
  final double cardWidth;
  const _FlowHomeworkSidebar({
    required this.studentId,
    required this.flows,
    required this.cardWidth,
  });

  @override
  State<_FlowHomeworkSidebar> createState() => _FlowHomeworkSidebarState();
}

class _FlowHomeworkSidebarState extends State<_FlowHomeworkSidebar> {
  late Future<Map<String, List<HomeworkAssignmentBrief>>> _assignmentsFuture;
  late Future<Map<String, List<HomeworkAssignmentCheck>>> _checksFuture;
  int _lastAssignmentRevision = -1;

  @override
  void initState() {
    super.initState();
    _reloadAssignmentData();
  }

  @override
  void didUpdateWidget(covariant _FlowHomeworkSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId) {
      _reloadAssignmentData();
    }
  }

  void _reloadAssignmentData() {
    _assignmentsFuture =
        HomeworkAssignmentStore.instance.loadAssignmentsForStudent(widget.studentId);
    _checksFuture =
        HomeworkAssignmentStore.instance.loadChecksForStudent(widget.studentId);
  }

  int _flowPriority(StudentFlow flow) {
    final name = flow.name.trim();
    if (name == '현행') return 0;
    if (name == '선행') return 1;
    return 2;
  }

  List<StudentFlow> _sortedFlows(List<StudentFlow> input) {
    final list = List<StudentFlow>.from(input);
    list.sort((a, b) {
      final pa = _flowPriority(a);
      final pb = _flowPriority(b);
      if (pa != pb) return pa - pb;
      if (pa == 2) {
        final oi = a.orderIndex.compareTo(b.orderIndex);
        if (oi != 0) return oi;
      }
      return a.name.compareTo(b.name);
    });
    return list;
  }

  Future<void> _renameFlow(BuildContext context, StudentFlow flow) async {
    final controller = ImeAwareTextEditingController(text: flow.name);
    final nextName = await showDialog<String?>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('플로우 이름 변경', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: '플로우 이름',
            labelStyle: const TextStyle(color: kDlgTextSub),
            filled: true,
            fillColor: kDlgFieldBg,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kDlgBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = nextName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == flow.name) return;
    try {
      final allFlows =
          await StudentFlowStore.instance.loadForStudent(widget.studentId, force: true);
      final base = allFlows.isNotEmpty ? allFlows : widget.flows;
      final updated = base
          .map((f) => f.id == flow.id ? f.copyWith(name: trimmed) : f)
          .toList();
      await StudentFlowStore.instance.saveFlows(widget.studentId, updated);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('플로우 이름 변경 실패')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkAssignmentStore.instance.revision,
      builder: (context, rev, _) {
        if (_lastAssignmentRevision != rev) {
          _lastAssignmentRevision = rev;
          _reloadAssignmentData();
        }
        return FutureBuilder<Map<String, List<HomeworkAssignmentBrief>>>(
          future: _assignmentsFuture,
          builder: (context, assignmentsSnapshot) {
            final assignmentsByItem =
                assignmentsSnapshot.data ??
                    const <String, List<HomeworkAssignmentBrief>>{};
            return FutureBuilder<Map<String, List<HomeworkAssignmentCheck>>>(
              future: _checksFuture,
              builder: (context, checksSnapshot) {
                final checksByItem =
                    checksSnapshot.data ??
                        const <String, List<HomeworkAssignmentCheck>>{};
                return ValueListenableBuilder<int>(
                  valueListenable: StudentFlowStore.instance.revision,
                  builder: (_, __, ___) {
                    final latest =
                        StudentFlowStore.instance.cached(widget.studentId);
                    final displayFlows = latest.isNotEmpty
                        ? latest.where((f) => f.enabled).toList()
                        : widget.flows;
                    final sortedFlows = _sortedFlows(displayFlows);
                    return ValueListenableBuilder<int>(
                      valueListenable: HomeworkStore.instance.revision,
                      builder: (_, __, ___) {
                        final allItems =
                            HomeworkStore.instance.items(widget.studentId);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (int i = 0; i < sortedFlows.length; i++) ...[
                              SizedBox(
                                width: widget.cardWidth,
                                child: _FlowHomeworkCard(
                                  flow: sortedFlows[i],
                                  studentId: widget.studentId,
                                  cardWidth: widget.cardWidth,
                                  items: allItems
                                      .where((e) =>
                                          e.flowId == sortedFlows[i].id)
                                      .toList(),
                                  assignmentsByItem: assignmentsByItem,
                                  checksByItem: checksByItem,
                                  onEditName: _flowPriority(sortedFlows[i]) <= 1
                                      ? null
                                      : () =>
                                          _renameFlow(context, sortedFlows[i]),
                                ),
                              ),
                              if (i != sortedFlows.length - 1)
                                const SizedBox(width: 16),
                            ],
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _BehaviorAssignmentSidebar extends StatefulWidget {
  final String studentId;
  final double cardWidth;

  const _BehaviorAssignmentSidebar({
    required this.studentId,
    required this.cardWidth,
  });

  @override
  State<_BehaviorAssignmentSidebar> createState() =>
      _BehaviorAssignmentSidebarState();
}

class _BehaviorAssignmentSidebarState extends State<_BehaviorAssignmentSidebar> {
  late Future<List<StudentBehaviorAssignment>> _assignmentsFuture;
  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _reloadAssignments();
  }

  @override
  void didUpdateWidget(covariant _BehaviorAssignmentSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId) {
      _reloadAssignments();
    }
  }

  void _reloadAssignments() {
    _assignmentsFuture =
        StudentBehaviorAssignmentStore.instance.loadForStudent(widget.studentId);
  }

  Future<void> _addBehavior() async {
    try {
      final cards = await LearningBehaviorCardService.instance.loadCards();
      if (!mounted) return;
      if (cards.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('커리큘럼 탭에서 행동 카드를 먼저 만들어 주세요.')),
        );
        return;
      }
      final selected = await _showBehaviorCatalogPicker(context, cards);
      if (!mounted || selected == null) return;
      await StudentBehaviorAssignmentStore.instance.addFromCard(
        studentId: widget.studentId,
        card: selected,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('행동 추가에 실패했어요: $e')),
      );
    }
  }

  Future<void> _deleteBehavior(StudentBehaviorAssignment item) async {
    try {
      await StudentBehaviorAssignmentStore.instance.delete(
        studentId: widget.studentId,
        assignmentId: item.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('행동 삭제에 실패했어요: $e')),
      );
    }
  }

  Future<void> _changeLevel(StudentBehaviorAssignment item, int delta) async {
    try {
      await StudentBehaviorAssignmentStore.instance.changeLevel(
        studentId: widget.studentId,
        assignmentId: item.id,
        delta: delta,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('레벨 변경에 실패했어요: $e')),
      );
    }
  }

  Widget _buildBehaviorCard(StudentBehaviorAssignment item) {
    final int maxLevel = item.safeLevelContents.length;
    final int levelNumber = item.safeSelectedLevelIndex + 1;
    final bool canLevelDown = levelNumber > 1;
    final bool canLevelUp = levelNumber < maxLevel;
    final String repeatLabel = item.isIrregular ? '비정기' : '${item.repeatDays}일 주기';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                repeatLabel,
                style: TextStyle(
                  color: item.isIrregular
                      ? const Color(0xFFF2B56B)
                      : const Color(0xFF9FB3B3),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2A34),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFF3A4C5A)),
                ),
                child: Text(
                  '레벨 $levelNumber',
                  style: const TextStyle(
                    color: Color(0xFFD4E6EA),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.selectedLevelText.trim().isEmpty
                      ? '(내용 없음)'
                      : item.selectedLevelText.trim(),
                  style: const TextStyle(
                    color: Color(0xFFD2DCDD),
                    fontSize: 13,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '레벨 다운',
                onPressed: canLevelDown ? () => _changeLevel(item, -1) : null,
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                ),
                color: const Color(0xFF9FB3B3),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '레벨 업',
                onPressed: canLevelUp ? () => _changeLevel(item, 1) : null,
                icon: const Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: 20,
                ),
                color: const Color(0xFF9FB3B3),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '삭제',
                onPressed: () => _deleteBehavior(item),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                color: const Color(0xFFB1BABA),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: StudentBehaviorAssignmentStore.instance.revision,
      builder: (_, rev, __) {
        if (_lastRevision != rev) {
          _lastRevision = rev;
          _reloadAssignments();
        }
        return FutureBuilder<List<StudentBehaviorAssignment>>(
          future: _assignmentsFuture,
          builder: (context, snapshot) {
            final assignments = snapshot.data ??
                StudentBehaviorAssignmentStore.instance.cached(widget.studentId);
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF10171A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF223131)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.self_improvement_rounded,
                        size: 20,
                        color: Color(0xFF9FB3B3),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '행동 리스트',
                        style: TextStyle(
                          color: Color(0xFFEAF2F2),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151C21),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xFF223131)),
                        ),
                        child: Text(
                          '${assignments.length}개',
                          style: const TextStyle(
                            color: Color(0xFF9FB3B3),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '행동 추가',
                        onPressed: _addBehavior,
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          color: Color(0xFF9FB3B3),
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF223131), height: 1),
                  const SizedBox(height: 12),
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      assignments.isEmpty)
                    const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF8AA5A5),
                        ),
                      ),
                    )
                  else if (assignments.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          '등록된 행동이 없습니다.',
                          style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: assignments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) =>
                            _buildBehaviorCard(assignments[index]),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

Future<LearningBehaviorCardRecord?> _showBehaviorCatalogPicker(
  BuildContext context,
  List<LearningBehaviorCardRecord> cards,
) async {
  final sorted = List<LearningBehaviorCardRecord>.from(cards)
    ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  String selectedId = sorted.first.id;

  return showDialog<LearningBehaviorCardRecord>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              '행동 카드 선택',
              style: TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w900,
              ),
            ),
            content: SizedBox(
              width: 420,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: kDlgBorder, height: 1),
                  itemBuilder: (_, index) {
                    final card = sorted[index];
                    final bool selected = selectedId == card.id;
                    final String repeatLabel =
                        card.isIrregular ? '비정기' : '${card.repeatDays}일 주기';
                    return InkWell(
                      onTap: () => setDialogState(() => selectedId = card.id),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Radio<String>(
                              value: card.id,
                              groupValue: selectedId,
                              activeColor: kDlgAccent,
                              onChanged: (value) {
                                if (value == null) return;
                                setDialogState(() => selectedId = value);
                              },
                            ),
                            const SizedBox(width: 4),
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: card.color.withOpacity(0.25),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: card.color.withOpacity(0.6),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Icon(card.icon, color: Colors.white, size: 18),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    card.name,
                                    style: TextStyle(
                                      color: kDlgText,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    repeatLabel,
                                    style: TextStyle(
                                      color: card.isIrregular
                                          ? const Color(0xFFF2B56B)
                                          : kDlgTextSub,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '레벨 ${card.safeSelectedLevelIndex + 1}',
                              style: const TextStyle(
                                color: kDlgTextSub,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  LearningBehaviorCardRecord selected = sorted.first;
                  for (final card in sorted) {
                    if (card.id == selectedId) {
                      selected = card;
                      break;
                    }
                  }
                  Navigator.of(dialogContext).pop(selected);
                },
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('추가'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _FlowHomeworkCard extends StatefulWidget {
  final StudentFlow flow;
  final String studentId;
  final double cardWidth;
  final List<HomeworkItem> items;
  final Map<String, List<HomeworkAssignmentBrief>> assignmentsByItem;
  final Map<String, List<HomeworkAssignmentCheck>> checksByItem;
  final VoidCallback? onEditName;
  const _FlowHomeworkCard({
    required this.flow,
    required this.studentId,
    required this.cardWidth,
    required this.items,
    required this.assignmentsByItem,
    required this.checksByItem,
    required this.onEditName,
  });

  @override
  State<_FlowHomeworkCard> createState() => _FlowHomeworkCardState();
}

class _FlowHomeworkCardState extends State<_FlowHomeworkCard> {
  final Set<String> _expandedIds = <String>{};

  DateTime? _sortKey(HomeworkItem item) {
    return item.completedAt ??
        item.firstStartedAt ??
        item.updatedAt ??
        item.createdAt ??
        item.runStart;
  }

  List<HomeworkItem> _sortedItems() {
    final list = List<HomeworkItem>.from(widget.items);
    list.sort((a, b) {
      final ka = _sortKey(a);
      final kb = _sortKey(b);
      if (ka == null && kb == null) return 0;
      if (ka == null) return 1;
      if (kb == null) return -1;
      return kb.compareTo(ka); // 최신이 위
    });
    return list;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    return DateFormat('MM.dd HH:mm').format(time);
  }

  String _formatDuration(HomeworkItem hw) {
    final runningMs = hw.runStart != null
        ? DateTime.now().difference(hw.runStart!).inMilliseconds
        : 0;
    final totalMs = hw.accumulatedMs + runningMs;
    final duration = Duration(milliseconds: totalMs);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  DateTime? _completedDate(HomeworkItem hw) {
    return hw.completedAt ?? hw.confirmedAt;
  }

  String _completedDateGroupKey(HomeworkItem hw) {
    final completed = _completedDate(hw);
    if (completed == null) return '미완료';
    return DateFormat('yyyy.MM.dd').format(completed);
  }

  Widget _buildCompletedDateDivider(String key) {
    final bool pending = key == '미완료';
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFF223131), height: 1)),
        const SizedBox(width: 8),
        Text(
          pending ? '미완료' : key,
          style: TextStyle(
            color: pending ? const Color(0xFF7A8787) : const Color(0xFF9FB3B3),
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: Color(0xFF223131), height: 1)),
      ],
    );
  }

  List<_HomeworkRoundData> _buildAssignmentRounds(
    List<HomeworkAssignmentBrief> assignments,
    List<HomeworkAssignmentCheck> checks,
  ) {
    if (checks.isEmpty) return const <_HomeworkRoundData>[];
    final sortedAssignments = List<HomeworkAssignmentBrief>.from(assignments)
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final sortedChecks = List<HomeworkAssignmentCheck>.from(checks)
      ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));

    final Map<String, HomeworkAssignmentBrief> assignmentById = {
      for (final assignment in sortedAssignments) assignment.id: assignment,
    };
    final Set<String> usedAssignmentIds = <String>{};

    HomeworkAssignmentBrief? fallbackFor(HomeworkAssignmentCheck check) {
      HomeworkAssignmentBrief? nearestBefore;
      for (final assignment in sortedAssignments) {
        if (assignment.assignedAt.isAfter(check.checkedAt)) break;
        if (!usedAssignmentIds.contains(assignment.id)) {
          nearestBefore = assignment;
        }
      }
      if (nearestBefore != null) return nearestBefore;
      for (final assignment in sortedAssignments) {
        if (!usedAssignmentIds.contains(assignment.id)) return assignment;
      }
      return sortedAssignments.isNotEmpty ? sortedAssignments.last : null;
    }

    final List<_HomeworkRoundData> rounds = <_HomeworkRoundData>[];
    for (int i = 0; i < sortedChecks.length; i++) {
      final check = sortedChecks[i];
      HomeworkAssignmentBrief? linked;
      final assignmentId = check.assignmentId;
      if (assignmentId != null && assignmentId.isNotEmpty) {
        linked = assignmentById[assignmentId];
      }
      linked ??= fallbackFor(check);
      if (linked != null) {
        usedAssignmentIds.add(linked.id);
      }
      rounds.add(
        _HomeworkRoundData(
          round: i + 1,
          assignedAt: linked?.assignedAt,
          checkedAt: check.checkedAt,
          progress: check.progress,
        ),
      );
    }
    return rounds;
  }

  Widget _metaItem(String label, String value) {
    final safe = value.trim().isEmpty ? '-' : value.trim();
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: safe,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _detailRow(String label, String value) {
    final safe = value.trim().isEmpty ? '-' : value.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            safe,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            softWrap: true,
          ),
        ),
      ],
    );
  }

  Widget _buildHomeworkCard(HomeworkItem hw) {
    final bool isCompleted = hw.status == HomeworkStatus.completed;
    final assignments = widget.assignmentsByItem[hw.id] ?? const <HomeworkAssignmentBrief>[];
    final checks = widget.checksByItem[hw.id] ?? const <HomeworkAssignmentCheck>[];
    final int assignmentCount = assignments.length;
    final String homeworkLabel = assignmentCount > 0 ? 'H$assignmentCount' : '';
    final int checkCount =
        checks.isNotEmpty ? checks.length : hw.checkCount;
    final DateTime? startTime =
        hw.firstStartedAt ?? hw.runStart ?? hw.createdAt ?? hw.updatedAt;
    final DateTime? endTime = isCompleted
        ? (hw.completedAt ?? hw.confirmedAt ?? hw.updatedAt)
        : null;
    final String type = (hw.type ?? '').trim();
    final String title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final String page = (hw.page ?? '').trim();
    final String count = hw.count != null ? hw.count.toString() : '';
    final String duration = _formatDuration(hw);
    final String content =
        (hw.content ?? '').trim().isNotEmpty ? (hw.content ?? '').trim() : hw.body.trim();

    final List<HomeworkAssignmentBrief> sortedAssignments =
        List<HomeworkAssignmentBrief>.from(assignments)
          ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final List<HomeworkAssignmentCheck> sortedChecks =
        List<HomeworkAssignmentCheck>.from(checks)
          ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    final List<_HomeworkRoundData> rounds = _buildAssignmentRounds(
      sortedAssignments,
      sortedChecks,
    );

    final bool expanded = _expandedIds.contains(hw.id);
    final Color borderColor = isCompleted
        ? const Color(0xFF223131).withOpacity(0.6)
        : const Color(0xFF223131);
    final Color bgColor = isCompleted
        ? const Color(0xFF0B1112).withOpacity(0.6)
        : const Color(0xFF0B1112);
    return Opacity(
      opacity: isCompleted ? 0.55 : 1.0,
      child: InkWell(
        onTap: () {
          setState(() {
            if (expanded) {
              _expandedIds.remove(hw.id);
            } else {
              _expandedIds.add(hw.id);
            }
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (type.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: hw.color.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: hw.color.withOpacity(0.6)),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          color: hw.color,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (type.isNotEmpty) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (homeworkLabel.isNotEmpty)
                    Text(
                      homeworkLabel,
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _metaItem('페이지', page),
                  _metaItem('문항수', count),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _metaItem('시작', _formatTime(startTime)),
                  _metaItem('총 걸린시간', duration),
                  _metaItem('검사횟수', checkCount.toString()),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    const Divider(color: Color(0xFF223131), height: 1),
                    const SizedBox(height: 10),
                    if (isCompleted)
                      _detailRow('종료시간', _formatTime(endTime)),
                    _detailRow('내용', content),
                    const SizedBox(height: 12),
                    const Text(
                      '숙제 회차',
                      style: TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (rounds.isEmpty)
                      const Text(
                        '검사 기록이 없습니다.',
                        style: TextStyle(
                          color: Color(0xFF9FB3B3),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0; i < rounds.length; i++) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 72,
                                    child: Text(
                                      '${rounds[i].round}회차',
                                      style: const TextStyle(
                                        color: Color(0xFFEAF2F2),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_formatTime(rounds[i].assignedAt)}  →  ${_formatTime(rounds[i].checkedAt)}',
                                          style: const TextStyle(
                                            color: Color(0xFFCBD8D8),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '완료율 ${rounds[i].progress}%',
                                          style: const TextStyle(
                                            color: Color(0xFF9FB3B3),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (i != rounds.length - 1)
                              const Divider(
                                color: Color(0xFF223131),
                                height: 12,
                                thickness: 1,
                              ),
                          ],
                        ],
                      ),
                  ],
                ),
                crossFadeState: expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 180),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedItems();
    final bool isWide = widget.cardWidth >= 460;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          padding: const EdgeInsets.fromLTRB(6, 14, 10, 14),
          decoration: const BoxDecoration(
            border: Border(
              right: BorderSide(color: Color(0xFF223131), width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 20, color: Color(0xFF9FB3B3)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.flow.name,
                      style: TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: isWide ? 34 : 30,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.onEditName != null)
                    IconButton(
                      tooltip: '이름 변경',
                      onPressed: widget.onEditName,
                      icon:
                          const Icon(Icons.edit, size: 19, color: Color(0xFF9FB3B3)),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _FlowTextbookSummary(
                flow: widget.flow,
                studentId: widget.studentId,
                homeworkItems: widget.items,
                cardWidth: widget.cardWidth,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text(
                    '과제 목록',
                    style: TextStyle(
                      color: Color(0xFF9FB3B3),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF151C21),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF223131)),
                    ),
                    child: Text(
                      '${sorted.length}개',
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (sorted.isEmpty)
                const Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      '등록된 과제가 없습니다.',
                      style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Builder(
                    builder: (_) {
                      final children = <Widget>[];
                      String? previousGroup;
                      for (int i = 0; i < sorted.length; i++) {
                        final hw = sorted[i];
                        final group = _completedDateGroupKey(hw);
                        if (group != previousGroup) {
                          if (children.isNotEmpty) {
                            children.add(const SizedBox(height: 8));
                          }
                          children.add(_buildCompletedDateDivider(group));
                          children.add(const SizedBox(height: 8));
                          previousGroup = group;
                        }
                        children.add(_buildHomeworkCard(hw));
                        if (i != sorted.length - 1) {
                          children.add(const SizedBox(height: 10));
                        }
                      }
                      return Scrollbar(
                        child: SingleChildScrollView(
                          child: Column(children: children),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeworkRoundData {
  final int round;
  final DateTime? assignedAt;
  final DateTime checkedAt;
  final int progress;

  const _HomeworkRoundData({
    required this.round,
    required this.assignedAt,
    required this.checkedAt,
    required this.progress,
  });
}

class _ChecklistBigNode {
  final String name;
  final int orderIndex;
  final List<_ChecklistMidNode> middles;
  bool selected;

  _ChecklistBigNode({
    required this.name,
    required this.orderIndex,
    required this.middles,
    this.selected = false,
  });
}

class _ChecklistMidNode {
  final String name;
  final int orderIndex;
  final List<_ChecklistSmallNode> smalls;
  bool selected;

  _ChecklistMidNode({
    required this.name,
    required this.orderIndex,
    required this.smalls,
    this.selected = false,
  });
}

class _ChecklistSmallNode {
  final String name;
  final int orderIndex;
  final int? startPage;
  final int? endPage;
  final String key;
  final Set<int> pages;
  final bool locked;
  final DateTime? finishedAt;
  bool selected;

  _ChecklistSmallNode({
    required this.name,
    required this.orderIndex,
    required this.startPage,
    required this.endPage,
    required this.key,
    required this.pages,
    this.locked = false,
    this.finishedAt,
    this.selected = false,
  });
}

class _FlowTextbookSummary extends StatefulWidget {
  final StudentFlow flow;
  final String studentId;
  final List<HomeworkItem> homeworkItems;
  final double cardWidth;
  const _FlowTextbookSummary({
    required this.flow,
    required this.studentId,
    required this.homeworkItems,
    required this.cardWidth,
  });

  @override
  State<_FlowTextbookSummary> createState() => _FlowTextbookSummaryState();
}

class _FlowTextbookSummaryState extends State<_FlowTextbookSummary> {
  static const AnimationStyle _checklistExpansionStyle = AnimationStyle(
    duration: Duration(milliseconds: 90),
    reverseDuration: Duration(milliseconds: 65),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  static final Map<String, Set<int>> _metadataPagesCacheByBookKey =
      <String, Set<int>>{};
  static final Map<String, Map<String, dynamic>?> _metadataPayloadCacheByBookKey =
      <String, Map<String, dynamic>?>{};
  static final Map<String, Map<String, Set<int>>> _metadataSmallPagesCacheByBookKey =
      <String, Map<String, Set<int>>>{};
  static final Map<String, String> _textbookTypeCacheByBookKey =
      <String, String>{};

  bool _loading = true;
  int _reqId = 0;
  List<Map<String, dynamic>> _linked = const <Map<String, dynamic>>[];
  Map<String, int> _totalPagesByKey = <String, int>{};
  Map<String, int> _completedPagesByKey = <String, int>{};
  Map<String, int> _acknowledgedPageCountByKey = <String, int>{};
  Map<String, Set<String>> _acknowledgedSmallKeysByBookKey =
      <String, Set<String>>{};
  Map<String, String> _typeLabelByKey = <String, String>{};

  String _fmtYmd(DateTime? dt) {
    if (dt == null) return '--.--.--';
    return DateFormat('yy.MM.dd').format(dt);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadLinks());
  }

  @override
  void didUpdateWidget(covariant _FlowTextbookSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow.id != widget.flow.id ||
        oldWidget.studentId != widget.studentId) {
      unawaited(_loadLinks());
      return;
    }
    _recalculateCompletedProgress();
  }

  bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  String _keyOf(Map<String, dynamic> row) {
    final bookId = (row['book_id'] as String?)?.trim() ?? '';
    final grade = (row['grade_label'] as String?)?.trim() ?? '';
    return '$bookId|$grade';
  }

  String _labelOf(Map<String, dynamic> row) {
    final book = (row['book_name'] as String?)?.trim() ?? '(이름 없음)';
    final grade = (row['grade_label'] as String?)?.trim() ?? '';
    return grade.isEmpty ? book : '$book · $grade';
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  void _addPageRange(Set<int> pages, int? a, int? b) {
    if (a == null && b == null) return;
    if (a != null && b != null) {
      int start = a;
      int end = b;
      if (start > end) {
        final tmp = start;
        start = end;
        end = tmp;
      }
      if (end - start > 1600) {
        if (start > 0) pages.add(start);
        if (end > 0) pages.add(end);
        return;
      }
      for (int p = start; p <= end; p++) {
        if (p > 0) pages.add(p);
      }
      return;
    }
    final single = a ?? b;
    if (single != null && single > 0) {
      pages.add(single);
    }
  }

  Set<int> _pagesFromMetadataPayload(dynamic payload) {
    final pages = <int>{};
    void walk(dynamic node) {
      if (node is Map) {
        final start = _toInt(node['start_page'] ?? node['startPage']);
        final end = _toInt(node['end_page'] ?? node['endPage']);
        _addPageRange(pages, start, end);

        final counts = node['page_counts'] ?? node['pageCounts'];
        if (counts is Map) {
          for (final key in counts.keys) {
            final page = _toInt(key);
            if (page != null && page > 0) pages.add(page);
          }
        }

        for (final value in node.values) {
          if (value is Map || value is List) {
            walk(value);
          }
        }
        return;
      }
      if (node is List) {
        for (final item in node) {
          if (item is Map || item is List) {
            walk(item);
          }
        }
      }
    }

    walk(payload);
    return pages;
  }

  String _smallKey(int bigOrder, int midOrder, int smallOrder) {
    return '$bigOrder|$midOrder|$smallOrder';
  }

  Map<String, Set<int>> _smallPagesFromMetadataPayload(dynamic payload) {
    final out = <String, Set<int>>{};
    if (payload is! Map) return out;
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return out;
    final units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort(
      (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
    );
    for (final big in units) {
      final bigOrder = _orderIndex(big['order_index']);
      final midsRaw = big['middles'];
      if (midsRaw is! List) continue;
      final mids = midsRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      mids.sort(
        (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
      );
      for (final mid in mids) {
        final midOrder = _orderIndex(mid['order_index']);
        final smallsRaw = mid['smalls'];
        if (smallsRaw is! List) continue;
        final smalls = smallsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        smalls.sort(
          (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
        );
        for (final small in smalls) {
          final smallOrder = _orderIndex(small['order_index']);
          final pages = <int>{};
          final start = _toInt(small['start_page']);
          final end = _toInt(small['end_page']);
          _addPageRange(pages, start, end);
          final counts = small['page_counts'];
          if (counts is Map) {
            for (final key in counts.keys) {
              final page = _toInt(key);
              if (page != null && page > 0) pages.add(page);
            }
          }
          out[_smallKey(bigOrder, midOrder, smallOrder)] = pages;
        }
      }
    }
    return out;
  }

  int _orderIndex(dynamic value) => _toInt(value) ?? (1 << 30);

  String _sanitizeTextbookType(dynamic value) {
    final raw = (value as String?)?.trim() ?? '';
    if (raw == '개념서' || raw == '문제집') return raw;
    return '';
  }

  String _ackPrefsKey(String bookKey) {
    return 'flow_textbook_ack_units_v1:${widget.studentId}|${widget.flow.id}|$bookKey';
  }

  Future<Map<String, Set<String>>> _loadAcknowledgedSmallKeysByLinks(
    List<Map<String, dynamic>> links,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Set<String>>{};
    for (final row in links) {
      final key = _keyOf(row);
      if (key == '|') continue;
      final values = prefs.getStringList(_ackPrefsKey(key)) ?? const <String>[];
      out[key] = values.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    }
    return out;
  }

  Future<void> _saveAcknowledgedSmallKeys(
    String bookKey,
    Set<String> selectedKeys,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = selectedKeys.toList()..sort();
    await prefs.setStringList(_ackPrefsKey(bookKey), list);
  }

  Set<int> _pagesFromUnitMappings(List<Map<String, dynamic>>? mappings) {
    final pages = <int>{};
    if (mappings == null || mappings.isEmpty) return pages;
    for (final raw in mappings) {
      final m = Map<String, dynamic>.from(raw);
      final start = _toInt(m['startPage'] ?? m['start_page']);
      final end = _toInt(m['endPage'] ?? m['end_page']);
      _addPageRange(pages, start, end);
    }
    return pages;
  }

  Set<int> _pagesFromRawPageText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <int>{};
    final normalized = trimmed
        .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
        .replaceAll('페이지', '')
        .replaceAll('쪽', '')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    final tokens = normalized
        .split(RegExp(r'[,/\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final pages = <int>{};
    for (final token in tokens) {
      if (token.contains('-')) {
        final parts = token
            .split('-')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length != 2) continue;
        _addPageRange(pages, _toInt(parts[0]), _toInt(parts[1]));
      } else {
        final value = _toInt(token);
        if (value != null && value > 0) {
          pages.add(value);
        }
      }
    }
    return pages;
  }

  bool _isCompletedForProgress(HomeworkItem hw) {
    return hw.status == HomeworkStatus.completed || hw.phase == 4;
  }

  Set<int> _completedPagesForHomework(HomeworkItem hw) {
    final byMapping = _pagesFromUnitMappings(hw.unitMappings);
    if (byMapping.isNotEmpty) return byMapping;
    return _pagesFromRawPageText(hw.page ?? '');
  }

  Future<void> _ensureMetadataCachesForBook(Map<String, dynamic> row) async {
    final key = _keyOf(row);
    if (key == '|') return;
    final hasPages = _metadataPagesCacheByBookKey.containsKey(key);
    final hasPayload = _metadataPayloadCacheByBookKey.containsKey(key);
    final hasType = _textbookTypeCacheByBookKey.containsKey(key);
    final hasSmallPages = _metadataSmallPagesCacheByBookKey.containsKey(key);
    if (hasPages && hasPayload && hasType && hasSmallPages) return;

    final bookId = (row['book_id'] as String?)?.trim() ?? '';
    final grade = (row['grade_label'] as String?)?.trim() ?? '';
    Map<String, dynamic>? payloadRow;
    if (bookId.isNotEmpty && grade.isNotEmpty) {
      try {
        payloadRow = await DataManager.instance.loadTextbookMetadataPayload(
          bookId: bookId,
          gradeLabel: grade,
        );
      } catch (_) {
        payloadRow = null;
      }
    }

    final payload = payloadRow?['payload'];
    _metadataPayloadCacheByBookKey[key] =
        payload is Map ? Map<String, dynamic>.from(payload) : null;
    _metadataPagesCacheByBookKey[key] = _pagesFromMetadataPayload(payload);
    _metadataSmallPagesCacheByBookKey[key] =
        _smallPagesFromMetadataPayload(payload);
    final metaType = _sanitizeTextbookType(payloadRow?['textbook_type']);
    _textbookTypeCacheByBookKey[key] = metaType.isEmpty ? '미지정' : metaType;
  }

  Future<Map<String, int>> _buildTotalPagesByKey(
    List<Map<String, dynamic>> links,
  ) async {
    final out = <String, int>{};
    for (final row in links) {
      final key = _keyOf(row);
      if (key == '|') continue;
      await _ensureMetadataCachesForBook(row);
      out[key] = (_metadataPagesCacheByBookKey[key] ?? const <int>{}).length;
    }
    return out;
  }

  Future<Map<String, String>> _buildTypeLabelsByKey(
    List<Map<String, dynamic>> links,
  ) async {
    final out = <String, String>{};
    for (final row in links) {
      final key = _keyOf(row);
      if (key == '|') continue;
      await _ensureMetadataCachesForBook(row);
      out[key] = _textbookTypeCacheByBookKey[key] ?? '미지정';
    }
    return out;
  }

  Map<String, int> _buildCompletedPagesByKey(
    List<Map<String, dynamic>> links, {
    required Map<String, int> totalPagesByKey,
    required Map<String, Set<String>> acknowledgedSmallKeysByBookKey,
    required Map<String, int> acknowledgedPageCountByKeyOut,
  }) {
    final completedSets = <String, Set<int>>{};
    for (final hw in widget.homeworkItems) {
      if (!_isCompletedForProgress(hw)) continue;
      final bookId = (hw.bookId ?? '').trim();
      final grade = (hw.gradeLabel ?? '').trim();
      if (bookId.isEmpty || grade.isEmpty) continue;
      final key = '$bookId|$grade';
      final set = completedSets.putIfAbsent(key, () => <int>{});
      set.addAll(_completedPagesForHomework(hw));
    }

    final out = <String, int>{};
    for (final row in links) {
      final key = _keyOf(row);
      final doneSet = <int>{...(completedSets[key] ?? const <int>{})};
      final ackSmallKeys =
          acknowledgedSmallKeysByBookKey[key] ?? const <String>{};
      final smallPagesByKey =
          _metadataSmallPagesCacheByBookKey[key] ?? const <String, Set<int>>{};
      final ackPages = <int>{};
      for (final smallKey in ackSmallKeys) {
        ackPages.addAll(smallPagesByKey[smallKey] ?? const <int>{});
      }
      acknowledgedPageCountByKeyOut[key] = ackPages.length;
      doneSet.addAll(ackPages);
      final totalPages = totalPagesByKey[key] ?? 0;
      if (totalPages <= 0) {
        out[key] = doneSet.length;
        continue;
      }
      final allowed = _metadataPagesCacheByBookKey[key];
      if (allowed == null || allowed.isEmpty) {
        out[key] = doneSet.length.clamp(0, totalPages);
        continue;
      }
      int matched = 0;
      for (final p in doneSet) {
        if (allowed.contains(p)) matched++;
      }
      out[key] = matched.clamp(0, totalPages);
    }
    return out;
  }

  void _recalculateCompletedProgress() {
    final ackCountByKey = <String, int>{};
    final next = _buildCompletedPagesByKey(
      _linked,
      totalPagesByKey: _totalPagesByKey,
      acknowledgedSmallKeysByBookKey: _acknowledgedSmallKeysByBookKey,
      acknowledgedPageCountByKeyOut: ackCountByKey,
    );
    final bool completedChanged = !_mapsEqual(next, _completedPagesByKey);
    final bool ackChanged =
        !_mapsEqual(ackCountByKey, _acknowledgedPageCountByKey);
    if ((completedChanged || ackChanged) && mounted) {
      setState(() {
        _completedPagesByKey = next;
        _acknowledgedPageCountByKey = ackCountByKey;
      });
    }
  }

  Future<void> _loadLinks() async {
    final id = ++_reqId;
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await DataManager.instance.loadFlowTextbookLinks(widget.flow.id);
      if (!mounted || id != _reqId) return;
      final list = List<Map<String, dynamic>>.from(rows);
      list.sort((a, b) {
        final ai = (a['order_index'] as int?) ?? 0;
        final bi = (b['order_index'] as int?) ?? 0;
        if (ai != bi) return ai.compareTo(bi);
        return _labelOf(a).compareTo(_labelOf(b));
      });
      final totalPagesByKey = await _buildTotalPagesByKey(list);
      if (!mounted || id != _reqId) return;
      final typeLabelByKey = await _buildTypeLabelsByKey(list);
      if (!mounted || id != _reqId) return;
      final acknowledgedSmallKeysByBookKey =
          await _loadAcknowledgedSmallKeysByLinks(list);
      if (!mounted || id != _reqId) return;
      final acknowledgedPageCountByKey = <String, int>{};
      final completedByKey = _buildCompletedPagesByKey(
        list,
        totalPagesByKey: totalPagesByKey,
        acknowledgedSmallKeysByBookKey: acknowledgedSmallKeysByBookKey,
        acknowledgedPageCountByKeyOut: acknowledgedPageCountByKey,
      );
      setState(() {
        _linked = list;
        _totalPagesByKey = totalPagesByKey;
        _typeLabelByKey = typeLabelByKey;
        _acknowledgedSmallKeysByBookKey = acknowledgedSmallKeysByBookKey;
        _acknowledgedPageCountByKey = acknowledgedPageCountByKey;
        _completedPagesByKey = completedByKey;
      });
    } catch (_) {
      if (!mounted || id != _reqId) return;
      setState(() {
        _linked = const <Map<String, dynamic>>[];
        _totalPagesByKey = <String, int>{};
        _completedPagesByKey = <String, int>{};
        _acknowledgedSmallKeysByBookKey = <String, Set<String>>{};
        _acknowledgedPageCountByKey = <String, int>{};
        _typeLabelByKey = <String, String>{};
      });
    } finally {
      if (mounted && id == _reqId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openLinkDialog() async {
    final candidates = await DataManager.instance.loadTextbooksWithMetadata();
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('메타데이터가 저장된 교재가 없습니다.')),
      );
      return;
    }

    final selected = <String>{for (final row in _linked) _keyOf(row)};
    final result = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) {
        final working = <String>{...selected};
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                '교재 연결',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
              ),
              content: SizedBox(
                width: 640,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '메타데이터가 저장된 교재만 표시됩니다. 여러 개 선택할 수 있어요.',
                      style: TextStyle(color: kDlgTextSub),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: kDlgBorder, height: 1),
                        itemBuilder: (ctx, i) {
                          final row = candidates[i];
                          final key = _keyOf(row);
                          final checked = working.contains(key);
                          return CheckboxListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            value: checked,
                            onChanged: (v) {
                              setLocal(() {
                                if (v == true) {
                                  working.add(key);
                                } else {
                                  working.remove(key);
                                }
                              });
                            },
                            activeColor: kDlgAccent,
                            side: const BorderSide(color: kDlgBorder),
                            title: Text(
                              _labelOf(row),
                              style: const TextStyle(
                                color: kDlgText,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    final selectedRows = <Map<String, dynamic>>[];
                    for (final row in candidates) {
                      if (working.contains(_keyOf(row))) {
                        selectedRows.add({
                          'book_id': row['book_id'],
                          'grade_label': row['grade_label'],
                          'book_name': row['book_name'],
                        });
                      }
                    }
                    Navigator.of(ctx).pop(selectedRows);
                  },
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return;

    try {
      await DataManager.instance.saveFlowTextbookLinks(widget.flow.id, result);
      if (!mounted) return;
      await _loadLinks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('교재 연결을 저장했습니다.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('교재 연결 저장 실패: $e')),
      );
    }
  }

  bool _allSmallSelected(_ChecklistMidNode mid) {
    return mid.smalls.isNotEmpty && mid.smalls.every((s) => s.selected);
  }

  bool _allMidSelected(_ChecklistBigNode big) {
    return big.middles.isNotEmpty && big.middles.every(_allSmallSelected);
  }

  bool _hasEditableSmallInMid(_ChecklistMidNode mid) {
    return mid.smalls.any((s) => !s.locked);
  }

  bool _hasEditableSmallInBig(_ChecklistBigNode big) {
    return big.middles.any(_hasEditableSmallInMid);
  }

  void _toggleBigNode(_ChecklistBigNode big, bool selected) {
    for (final mid in big.middles) {
      for (final small in mid.smalls) {
        if (small.locked) continue;
        small.selected = selected;
      }
      mid.selected = _allSmallSelected(mid);
    }
    big.selected = _allMidSelected(big);
  }

  void _toggleMidNode(
    _ChecklistBigNode big,
    _ChecklistMidNode mid,
    bool selected,
  ) {
    for (final small in mid.smalls) {
      if (small.locked) continue;
      small.selected = selected;
    }
    mid.selected = _allSmallSelected(mid);
    big.selected = _allMidSelected(big);
  }

  void _toggleSmallNode(
    _ChecklistBigNode big,
    _ChecklistMidNode mid,
    _ChecklistSmallNode small,
    bool selected,
  ) {
    if (small.locked) return;
    small.selected = selected;
    mid.selected = _allSmallSelected(mid);
    big.selected = _allMidSelected(big);
  }

  Set<String> _selectedChecklistSmallKeys(List<_ChecklistBigNode> nodes) {
    final out = <String>{};
    for (final big in nodes) {
      for (final mid in big.middles) {
        for (final small in mid.smalls) {
          if (small.selected && !small.locked) out.add(small.key);
        }
      }
    }
    return out;
  }

  List<_ChecklistBigNode> _parseChecklistNodes(
    dynamic payload,
    Set<String> selectedKeys,
    Map<String, DateTime?> lockedFinishedAtByKey,
  ) {
    if (payload is! Map) return const <_ChecklistBigNode>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_ChecklistBigNode>[];
    final units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort(
      (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
    );

    final out = <_ChecklistBigNode>[];
    for (final bigRaw in units) {
      final bigOrder = _orderIndex(bigRaw['order_index']);
      final bigName = (bigRaw['name'] as String?)?.trim().isNotEmpty == true
          ? (bigRaw['name'] as String).trim()
          : '대단원';

      final midsRaw = bigRaw['middles'];
      final midsList = midsRaw is List
          ? midsRaw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      midsList.sort(
        (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
      );

      final mids = <_ChecklistMidNode>[];
      for (final midRaw in midsList) {
        final midOrder = _orderIndex(midRaw['order_index']);
        final midName = (midRaw['name'] as String?)?.trim().isNotEmpty == true
            ? (midRaw['name'] as String).trim()
            : '중단원';

        final smallsRaw = midRaw['smalls'];
        final smallsList = smallsRaw is List
            ? smallsRaw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : <Map<String, dynamic>>[];
        smallsList.sort(
          (a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])),
        );

        final smalls = <_ChecklistSmallNode>[];
        for (final smallRaw in smallsList) {
          final smallOrder = _orderIndex(smallRaw['order_index']);
          final smallName =
              (smallRaw['name'] as String?)?.trim().isNotEmpty == true
                  ? (smallRaw['name'] as String).trim()
                  : '소단원';
          final startPage = _toInt(smallRaw['start_page']);
          final endPage = _toInt(smallRaw['end_page']);
          final pages = <int>{};
          _addPageRange(pages, startPage, endPage);
          final pageCounts = smallRaw['page_counts'];
          if (pageCounts is Map) {
            for (final key in pageCounts.keys) {
              final page = _toInt(key);
              if (page != null && page > 0) pages.add(page);
            }
          }
          final unitKey = _smallKey(bigOrder, midOrder, smallOrder);
          final lockedAt = lockedFinishedAtByKey[unitKey];
          final isLocked = lockedFinishedAtByKey.containsKey(unitKey);
          smalls.add(
            _ChecklistSmallNode(
              name: smallName,
              orderIndex: smallOrder,
              startPage: startPage,
              endPage: endPage,
              key: unitKey,
              pages: pages,
              selected: selectedKeys.contains(unitKey) || isLocked,
              locked: isLocked,
              finishedAt: lockedAt,
            ),
          );
        }

        final mid = _ChecklistMidNode(
          name: midName,
          orderIndex: midOrder,
          smalls: smalls,
        );
        mid.selected = _allSmallSelected(mid);
        mids.add(mid);
      }

      final big = _ChecklistBigNode(
        name: bigName,
        orderIndex: bigOrder,
        middles: mids,
      );
      big.selected = _allMidSelected(big);
      out.add(big);
    }
    return out;
  }

  String _smallPageText(_ChecklistSmallNode small) {
    if (small.startPage == null && small.endPage == null && small.pages.isEmpty) {
      return '';
    }
    if (small.startPage != null && small.endPage != null) {
      if (small.startPage == small.endPage) return 'p.${small.startPage}';
      return 'p.${small.startPage}-${small.endPage}';
    }
    if (small.startPage != null) return 'p.${small.startPage}';
    if (small.endPage != null) return 'p.${small.endPage}';
    if (small.pages.isNotEmpty) return '${small.pages.length}p';
    return '';
  }

  bool _hasPageOverlap(Set<int> a, Set<int> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    for (final p in small) {
      if (large.contains(p)) return true;
    }
    return false;
  }

  Map<String, DateTime?> _issuedSmallFinishedAtByBook(
    Map<String, dynamic> row,
  ) {
    final bookId = (row['book_id'] as String?)?.trim() ?? '';
    final grade = (row['grade_label'] as String?)?.trim() ?? '';
    if (bookId.isEmpty || grade.isEmpty) return <String, DateTime?>{};
    final bookKey = '$bookId|$grade';
    final smallPagesByKey =
        _metadataSmallPagesCacheByBookKey[bookKey] ?? const <String, Set<int>>{};
    if (smallPagesByKey.isEmpty) return <String, DateTime?>{};

    final issued = <String, DateTime?>{};
    for (final hw in widget.homeworkItems) {
      final hwBookId = (hw.bookId ?? '').trim();
      final hwGrade = (hw.gradeLabel ?? '').trim();
      if (hwBookId != bookId || hwGrade != grade) continue;
      if (!_isCompletedForProgress(hw)) continue;

      final finishedAt = hw.completedAt ??
          hw.confirmedAt ??
          hw.submittedAt ??
          hw.updatedAt ??
          hw.createdAt;
      final touched = <String>{};
      final mappings = hw.unitMappings;
      if (mappings != null && mappings.isNotEmpty) {
        for (final raw in mappings) {
          final m = Map<String, dynamic>.from(raw);
          final bigOrder = _toInt(m['bigOrder'] ?? m['big_order']);
          final midOrder = _toInt(m['midOrder'] ?? m['mid_order']);
          final smallOrder = _toInt(m['smallOrder'] ?? m['small_order']);
          if (bigOrder == null || midOrder == null || smallOrder == null) continue;
          touched.add(_smallKey(bigOrder, midOrder, smallOrder));
        }
      }

      final pages = _pagesFromRawPageText(hw.page ?? '');
      if (pages.isNotEmpty) {
        for (final entry in smallPagesByKey.entries) {
          if (_hasPageOverlap(pages, entry.value)) {
            touched.add(entry.key);
          }
        }
      }
      for (final key in touched) {
        final prev = issued[key];
        if (prev == null) {
          issued[key] = finishedAt;
          continue;
        }
        if (finishedAt != null && finishedAt.isAfter(prev)) {
          issued[key] = finishedAt;
        }
      }
    }
    return issued;
  }

  Widget _buildChecklistTreeCheckbox({
    required bool value,
    required ValueChanged<bool?>? onChanged,
    bool disabled = false,
  }) {
    final isDisabled = disabled || onChanged == null;
    return SizedBox(
      width: 22,
      height: 22,
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        activeColor: isDisabled ? const Color(0xFF3A4448) : kDlgAccent,
        checkColor: isDisabled ? const Color(0xFF9FB3B3) : Colors.white,
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (isDisabled) {
            return value ? const Color(0xFF2F3A3E) : const Color(0xFF1F282C);
          }
          if (states.contains(MaterialState.selected)) return kDlgAccent;
          return null;
        }),
        side: BorderSide(color: isDisabled ? const Color(0xFF3A4448) : kDlgBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }

  Future<void> _openProgressChecklistDialog(Map<String, dynamic> row) async {
    final key = _keyOf(row);
    if (key == '|') return;
    await _ensureMetadataCachesForBook(row);
    final issuedLockedAtByKey = _issuedSmallFinishedAtByBook(row);
    final payload = _metadataPayloadCacheByBookKey[key];
    final selectedBefore =
        Set<String>.from(_acknowledgedSmallKeysByBookKey[key] ?? const <String>{});
    final nodes = _parseChecklistNodes(
      payload,
      selectedBefore,
      issuedLockedAtByKey,
    );
    if (!mounted) return;
    if (nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('메타데이터 단원 정보가 없어 인정 진도를 설정할 수 없습니다.')),
      );
      return;
    }

    final selectedAfter = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                '진행률 체크',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
              ),
              content: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '이전 학원 진도/자습 진도를 체크하면 해당 범위를 완료로 인정합니다.',
                      style: TextStyle(color: kDlgTextSub),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 430),
                      child: Theme(
                        data: Theme.of(ctx).copyWith(
                          dividerColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          children: [
                            for (final big in nodes)
                              ExpansionTile(
                                expansionAnimationStyle: _checklistExpansionStyle,
                                tilePadding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 2,
                                ),
                                childrenPadding:
                                    const EdgeInsets.fromLTRB(10, 0, 10, 8),
                                maintainState: true,
                                iconColor: kDlgTextSub,
                                collapsedIconColor: kDlgTextSub,
                                title: Row(
                                  children: [
                                    _buildChecklistTreeCheckbox(
                                      value: big.selected,
                                      onChanged: _hasEditableSmallInBig(big)
                                          ? (v) {
                                              setLocal(() {
                                                _toggleBigNode(big, v ?? false);
                                              });
                                            }
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        big.name,
                                        style: const TextStyle(
                                          color: kDlgText,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                children: [
                                  for (final mid in big.middles)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: ExpansionTile(
                                        expansionAnimationStyle:
                                            _checklistExpansionStyle,
                                        tilePadding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 1,
                                        ),
                                        childrenPadding:
                                            const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                        maintainState: true,
                                        iconColor: kDlgTextSub,
                                        collapsedIconColor: kDlgTextSub,
                                        title: Row(
                                          children: [
                                            _buildChecklistTreeCheckbox(
                                              value: mid.selected,
                                              onChanged: _hasEditableSmallInMid(mid)
                                                  ? (v) {
                                                      setLocal(() {
                                                        _toggleMidNode(
                                                          big,
                                                          mid,
                                                          v ?? false,
                                                        );
                                                      });
                                                    }
                                                  : null,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                mid.name,
                                                style: const TextStyle(
                                                  color: kDlgText,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        children: [
                                          for (final small in mid.smalls)
                                            Padding(
                                              padding: const EdgeInsets.fromLTRB(
                                                4,
                                                3,
                                                4,
                                                3,
                                              ),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                mouseCursor: small.locked
                                                    ? SystemMouseCursors.basic
                                                    : SystemMouseCursors.click,
                                                onTap: small.locked
                                                    ? null
                                                    : () {
                                                        setLocal(() {
                                                          _toggleSmallNode(
                                                            big,
                                                            mid,
                                                            small,
                                                            !small.selected,
                                                          );
                                                        });
                                                      },
                                                child: AnimatedContainer(
                                                  duration: const Duration(
                                                    milliseconds: 140,
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 7,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: small.locked
                                                        ? const Color(0x1F0F1518)
                                                        : (small.selected
                                                            ? const Color(
                                                                0x1A33A373)
                                                            : Colors.transparent),
                                                    borderRadius:
                                                        BorderRadius.circular(8),
                                                    border: Border.all(
                                                      color: small.locked
                                                          ? const Color(
                                                              0xFF2E3C3F)
                                                          : (small.selected
                                                              ? kDlgAccent
                                                                  .withOpacity(
                                                                      0.9)
                                                              : kDlgBorder
                                                                  .withOpacity(
                                                                      0.8)),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      _buildChecklistTreeCheckbox(
                                                        value: small.selected,
                                                        onChanged: small.locked
                                                            ? null
                                                            : (v) {
                                                                setLocal(() {
                                                                  _toggleSmallNode(
                                                                    big,
                                                                    mid,
                                                                    small,
                                                                    v ?? false,
                                                                  );
                                                                });
                                                              },
                                                        disabled: small.locked,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Expanded(
                                                        child: Text(
                                                          small.name,
                                                          style:
                                                              TextStyle(
                                                            color: small.locked
                                                                ? const Color(
                                                                    0xFF6D7777)
                                                                : kDlgTextSub,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            fontSize: 12.5,
                                                            height: 1.2,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      if (small.locked) ...[
                                                        Text(
                                                          '완료 ${_fmtYmd(small.finishedAt)}',
                                                          style: const TextStyle(
                                                            color: Color(0xFF6D7777),
                                                            fontSize: 11.2,
                                                            fontWeight: FontWeight.w700,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 8),
                                                      ],
                                                      Text(
                                                        _smallPageText(small),
                                                        style: TextStyle(
                                                          color: small.locked
                                                              ? const Color(
                                                                  0xFF6D7777)
                                                              : kDlgTextSub,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop(_selectedChecklistSmallKeys(nodes));
                  },
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );
    if (selectedAfter == null) return;

    await _saveAcknowledgedSmallKeys(key, selectedAfter);
    if (!mounted) return;
    final nextAck = <String, Set<String>>{
      for (final entry in _acknowledgedSmallKeysByBookKey.entries)
        entry.key: <String>{...entry.value},
    };
    nextAck[key] = <String>{...selectedAfter};
    final ackPageCountByKey = <String, int>{};
    final nextCompleted = _buildCompletedPagesByKey(
      _linked,
      totalPagesByKey: _totalPagesByKey,
      acknowledgedSmallKeysByBookKey: nextAck,
      acknowledgedPageCountByKeyOut: ackPageCountByKey,
    );
    setState(() {
      _acknowledgedSmallKeysByBookKey = nextAck;
      _acknowledgedPageCountByKey = ackPageCountByKey;
      _completedPagesByKey = nextCompleted;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('인정 진도를 저장했습니다.')),
    );
  }

  Widget _buildTypeBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF172126),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF2B3C42)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF9FB3B3),
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildLinkedTextbookCard(Map<String, dynamic> row, int index) {
    final key = _keyOf(row);
    final totalPages = _totalPagesByKey[key] ?? 0;
    final donePagesRaw = _completedPagesByKey[key] ?? 0;
    final donePages = totalPages > 0 ? donePagesRaw.clamp(0, totalPages) : donePagesRaw;
    final ratio = (totalPages > 0) ? (donePages / totalPages) : 0.0;
    final typeLabel = _typeLabelByKey[key] ?? '미지정';
    final ackPages = _acknowledgedPageCountByKey[key] ?? 0;
    final bool hasTotal = totalPages > 0;
    final progressText = hasTotal
        ? '$donePages / $totalPages 페이지 완료${ackPages > 0 ? ' · 인정 ${ackPages}p' : ''}'
        : (donePages > 0
              ? '$donePages 페이지 완료 · 메타데이터 전체 페이지 미설정'
              : '메타데이터 전체 페이지 정보가 없습니다.');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(_openProgressChecklistDialog(row)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1418),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF223131)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B2730),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF2A3942)),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Color(0xFFCBD8D8),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LatexTextRenderer(
                      _labelOf(row),
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      softWrap: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildTypeBadge(typeLabel),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      progressText,
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    hasTotal ? '${(ratio * 100).round()}%' : '-',
                    style: const TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '클릭해서 진도를 체크하세요.',
                style: TextStyle(
                  color: Color(0xFF6F8080),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: hasTotal ? ratio : 0,
                  minHeight: 7,
                  backgroundColor: const Color(0xFF1B252B),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFF33A373)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWide = widget.cardWidth >= 460;
    return Container(
      padding: EdgeInsets.all(isWide ? 14 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F181D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_outlined,
                  size: 18, color: Color(0xFF9FB3B3)),
              const SizedBox(width: 8),
              const Text(
                '교재',
                style: TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF151C21),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFF223131)),
                ),
                child: Text(
                  '${_linked.length}권',
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _openLinkDialog,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('연결'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF9FB3B3),
                  side: const BorderSide(color: Color(0xFF4D5A5A)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  visualDensity:
                      const VisualDensity(horizontal: -3, vertical: -3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFF9FB3B3)),
                ),
              ),
            )
          else if (_linked.isEmpty)
            const Text(
              '등록된 교재가 없습니다.',
              style: TextStyle(
                color: Color(0xFF9FB3B3),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < _linked.length; i++) ...[
                  _buildLinkedTextbookCard(_linked[i], i),
                  if (i != _linked.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _FlowStatRow extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _FlowStatRow({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFB9C8C8),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          value.toString(),
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _TimelineEntry {
  final DateTime time;
  final IconData icon;
  final Color color;
  final String label;
  final String? note;
  final bool isTag;
  final String? setId;
  final String? studentId;
  final int? rawColorValue;
  final int? rawIconCodePoint;

  _TimelineEntry({
    required this.time,
    required this.icon,
    required this.color,
    required this.label,
    this.note,
    required this.isTag,
    this.setId,
    this.studentId,
    this.rawColorValue,
    this.rawIconCodePoint,
  });
}

class _TimelineHeader {
  final DateTime date;
  _TimelineHeader({required this.date});
}