import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import '../services/student_attendance_session.dart';
import '../services/student_point_session.dart';
import '../widgets/student_attendance_score_card.dart';
import '../widgets/student_page_title.dart';
import '../widgets/student_recent_attendance_panel.dart';

/// 출결 점수 + 오늘 출결 조회. 프로필·테마·로그아웃은 상단 계정 시트에서 처리.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _sectionKey = GlobalKey<_AttendanceScoreSectionState>();

  @override
  Widget build(BuildContext context) {
    return StudentCollapsingTitlePage(
      title: '내 정보',
      onRefresh: () => _sectionKey.currentState?.refresh() ?? Future.value(),
      bodyBuilder: (context, topInset, bottomInset) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, bottomInset),
          child: _AttendanceScoreSection(key: _sectionKey),
        );
      },
    );
  }
}

/// 출석 점수 요약 + (탭 시) 오늘 출결·최근 10회 상세.
/// 과제 메뉴 `_TodayHomeworkProgressSection` 과 동일한 펼침/로딩 타이밍.
class _AttendanceScoreSection extends StatefulWidget {
  const _AttendanceScoreSection({super.key});

  @override
  State<_AttendanceScoreSection> createState() =>
      _AttendanceScoreSectionState();
}

class _AttendanceScoreSectionState extends State<_AttendanceScoreSection> {
  AttendanceScoreInfo? _score;
  bool _loadingScore = true;
  String? _scoreError;

  HomeworkScoreInfo? _homework;
  bool _loadingHomework = true;
  String? _homeworkError;

  PointSummaryInfo? get _points => StudentPointSession.instance.summary;
  bool get _loadingPoints => StudentPointSession.instance.loading;
  String? get _pointsError => StudentPointSession.instance.error;

  StudentDesiredLevelInfo _desired = const StudentDesiredLevelInfo();
  bool _savingDesired = false;

  bool _expanded = false;
  TodayAttendance? _attendance;
  List<RecentAttendanceSession>? _recent;
  bool _loadingAttendance = false;
  String? _attendanceError;

  bool _pointsExpanded = false;
  List<PointHistoryEntry>? _pointHistory;
  bool _loadingPointHistory = false;
  String? _pointHistoryError;

  @override
  void initState() {
    super.initState();
    _attendance = StudentAttendanceSession.instance.today;
    StudentAttendanceSession.instance.addListener(_onAttendanceSessionChanged);
    StudentPointSession.instance.addListener(_onPointsChanged);
    unawaited(_loadScore());
    unawaited(_loadHomework());
    unawaited(_loadDesired());
    if (StudentPointSession.instance.summary == null) {
      unawaited(StudentPointSession.instance.refresh());
    }
  }

  @override
  void dispose() {
    StudentAttendanceSession.instance.removeListener(_onAttendanceSessionChanged);
    StudentPointSession.instance.removeListener(_onPointsChanged);
    super.dispose();
  }

  void _onPointsChanged() {
    if (!mounted) return;
    setState(() {});
    if (_pointsExpanded) {
      unawaited(_ensurePointHistoryLoaded(force: true));
    }
  }

  void _onAttendanceSessionChanged() {
    if (!mounted) return;
    setState(() {
      _attendance = StudentAttendanceSession.instance.today;
    });
  }

  Future<void> refresh() async {
    await Future.wait([
      _loadScore(),
      _loadHomework(),
      StudentPointSession.instance.refresh(),
      _loadDesired(),
    ]);
    if (_expanded) {
      await _ensureAttendanceLoaded(force: true);
    }
    if (_pointsExpanded) {
      await _ensurePointHistoryLoaded(force: true);
    }
  }

  Future<void> _loadScore() async {
    setState(() {
      _loadingScore = true;
      _scoreError = null;
    });
    try {
      final score = await StudentApi.instance.getAttendanceScore();
      if (!mounted) return;
      setState(() {
        _score = score;
        _loadingScore = false;
        _scoreError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scoreError = '출석 점수를 불러오지 못했어요.';
        _loadingScore = false;
      });
    }
  }

  Future<void> _loadHomework() async {
    setState(() {
      _loadingHomework = true;
      _homeworkError = null;
    });
    try {
      final homework = await StudentApi.instance.getHomeworkScore();
      if (!mounted) return;
      setState(() {
        _homework = homework;
        _loadingHomework = false;
        _homeworkError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeworkError = '과제 점수를 불러오지 못했어요.';
        _loadingHomework = false;
      });
    }
  }

  Future<void> _loadDesired() async {
    try {
      final desired = await StudentApi.instance.getDesiredLevel();
      if (!mounted) return;
      setState(() => _desired = desired);
    } catch (_) {
      // 총점 카드는 유지하고 목표는 플레이스홀더로 둔다.
    }
  }

  Future<void> _openDesiredPicker() async {
    if (_savingDesired) return;
    var options = _desired.options;
    if (options.isEmpty) {
      try {
        final fresh = await StudentApi.instance.getDesiredLevel();
        if (!mounted) return;
        setState(() => _desired = fresh);
        options = fresh.options;
      } catch (_) {}
    }
    if (!mounted) return;
    if (options.isEmpty) {
      TopGlassSnackBar.show(
        context,
        message: '목표 선택지를 불러오지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
      return;
    }

    final picked = await showModalBottomSheet<_DesiredLevelPick>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _DesiredLevelSheet(
        options: options,
        selectedTopPercent: _desired.upperPercent?.round(),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked.topPercent == _desired.upperPercent?.round()) return;

    setState(() => _savingDesired = true);
    try {
      final saved =
          await StudentApi.instance.setDesiredLevel(picked.topPercent);
      if (!mounted) return;
      setState(() {
        _desired = StudentDesiredLevelInfo(
          levelCode: saved.levelCode,
          upperPercent: saved.upperPercent,
          displayName: saved.displayName,
          options: options,
        );
        _savingDesired = false;
      });
      TopGlassSnackBar.show(
        context,
        message: picked.topPercent == null
            ? '내 목표를 지웠어요.'
            : '내 목표를 ${saved.goalValueLabel}로 저장했어요.',
        icon: Icons.check_circle_outline_rounded,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingDesired = false);
      TopGlassSnackBar.show(
        context,
        message: '내 목표를 저장하지 못했어요.',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> _toggle() async {
    final next = !_expanded;
    setState(() => _expanded = next);
    if (next) await _ensureAttendanceLoaded(force: true);
  }

  Future<void> _togglePoints() async {
    final next = !_pointsExpanded;
    setState(() => _pointsExpanded = next);
    if (next) await _ensurePointHistoryLoaded();
  }

  Future<void> _ensurePointHistoryLoaded({bool force = false}) async {
    if (!force && (_pointHistory != null || _loadingPointHistory)) return;
    setState(() {
      _loadingPointHistory = true;
      _pointHistoryError = null;
    });
    try {
      final rows = await StudentApi.instance.listRecentPoints(limit: 20);
      if (!mounted) return;
      setState(() {
        _pointHistory = rows;
        _loadingPointHistory = false;
      });
    } catch (e) {
      debugPrint('[points] history load failed: $e');
      if (!mounted) return;
      setState(() {
        _pointHistoryError = '포인트 내역을 불러오지 못했어요.';
        _loadingPointHistory = false;
      });
    }
  }

  Future<void> _ensureAttendanceLoaded({bool force = false}) async {
    if (!force &&
        ((_attendance != null && _recent != null) || _loadingAttendance)) {
      return;
    }
    setState(() {
      _loadingAttendance = true;
      _attendanceError = null;
    });
    try {
      await StudentAttendanceSession.instance.refresh();
      final recent =
          await StudentApi.instance.listRecentAttendance(limit: 10);
      if (!mounted) return;
      setState(() {
        _attendance = StudentAttendanceSession.instance.today;
        _recent = recent;
        _loadingAttendance = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _attendanceError = '출결 정보를 불러오지 못했어요.';
        _loadingAttendance = false;
      });
    }
  }

  static String _formatTime(DateTime? dt) {
    if (dt == null) return '기록 없음';
    return '${dt.hour}:${'${dt.minute}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final score = _score;

    if (_scoreError != null && score == null && !_loadingScore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Text(
              _scoreError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: sub),
            ),
            TextButton(
              onPressed: () => unawaited(_loadScore()),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }

    if (_loadingScore && score == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: YggLoadingIndicator(size: 32)),
      );
    }

    // 상단: 누적 포인트(lifetime_earned). 학습앱 포인트와 동일 기준.
    final points = _points;
    final String pointsSubtitle;
    if (_loadingPoints && points == null) {
      pointsSubtitle = '포인트를 불러오는 중…';
    } else if (points == null) {
      pointsSubtitle = _pointsError ?? '포인트를 불러오지 못했어요';
    } else {
      pointsSubtitle = points.subtitle;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudentAttendanceScoreCard(
          title: '',
          valueLabel: points?.lifetimeLabel,
          subtitle: pointsSubtitle,
          showProgressBar: false,
          unit: 'P',
          goalTitle: '내 목표',
          goalValue: _desired.goalValueLabel,
          onGoalTap: () => unawaited(_openDesiredPicker()),
          onTap: () => unawaited(_togglePoints()),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: _pointsExpanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 28),
                    Text(
                      '최근 받은 포인트',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                        color: sub,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _RecentPointHistoryCard(
                      entries: _pointHistory,
                      loading: _loadingPointHistory,
                      error: _pointHistoryError,
                      onRetry: () =>
                          unawaited(_ensurePointHistoryLoaded(force: true)),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 28),
        StudentAttendanceScoreCard(
          title: '출석 점수',
          score100: score?.score100,
          subtitle: score == null
              ? (_loadingScore
                  ? '출석 점수를 불러오는 중…'
                  : (_scoreError ?? '출석 점수를 불러오지 못했어요'))
              : score.subtitle,
          onTap: () => unawaited(_toggle()),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 28),
                    Text(
                      '오늘 출결',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                        color: sub,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _TodayAttendanceDetailCard(
                      attendance: _attendance,
                      recent: _recent,
                      loading: _loadingAttendance,
                      error: _attendanceError,
                      formatTime: _formatTime,
                      onRetry: () =>
                          unawaited(_ensureAttendanceLoaded(force: true)),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 28),
        // 펼침 상세는 아직 미정 — 요약 카드만 출석과 동일 양식으로 표시.
        StudentAttendanceScoreCard(
          title: '과제 점수',
          score100: _homework?.score100,
          subtitle: _homework == null
              ? (_loadingHomework
                  ? '과제 점수를 불러오는 중…'
                  : (_homeworkError ?? '과제 점수를 불러오지 못했어요'))
              : _homework!.subtitle,
        ),
      ],
    );
  }
}

/// 출석 펼침 카드와 같은 셸. 최근 적립 목록(과제는 그룹 단위).
class _RecentPointHistoryCard extends StatefulWidget {
  const _RecentPointHistoryCard({
    required this.entries,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final List<PointHistoryEntry>? entries;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  State<_RecentPointHistoryCard> createState() =>
      _RecentPointHistoryCardState();
}

class _RecentPointHistoryCardState extends State<_RecentPointHistoryCard> {
  static const _cardRadius = 22.0;
  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  final Set<String> _expanded = <String>{};

  static String _whenLabel(DateTime dt) {
    final wd = _weekdays[(dt.weekday - 1).clamp(0, 6)];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}월 ${dt.day}일 $wd요일 · $h:$m';
  }

  void _toggle(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFC6C6C8);
    final accent = isDark
        ? Colors.white.withValues(alpha: 0.78)
        : const Color(0xFF3A3A3C);

    final rows = widget.entries ?? const <PointHistoryEntry>[];
    final hasBody = widget.entries != null;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.loading && !hasBody)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: YggLoadingIndicator(size: 28)),
            )
          else if (widget.error != null && !hasBody)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                children: [
                  Text(
                    widget.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: subText),
                  ),
                  TextButton(
                    onPressed: widget.onRetry,
                    child: const Text('다시 시도'),
                  ),
                ],
              ),
            )
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              child: Text(
                '아직 받은 포인트가 없어요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: subText),
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Divider(height: 1, thickness: 0.33, color: divider),
                ),
              _PointHistoryRow(
                entry: rows[i],
                whenLabel: _whenLabel(rows[i].createdAt),
                text: text,
                sub: subText,
                accent: accent,
                expanded: _expanded.contains(rows[i].id),
                onToggleDetail: rows[i].canExpand
                    ? () => _toggle(rows[i].id)
                    : null,
              ),
            ],
        ],
      ),
    );
  }
}

class _PointHistoryRow extends StatelessWidget {
  const _PointHistoryRow({
    required this.entry,
    required this.whenLabel,
    required this.text,
    required this.sub,
    required this.accent,
    this.expanded = false,
    this.onToggleDetail,
    this.nested = false,
  });

  final PointHistoryEntry entry;
  final String whenLabel;
  final Color text;
  final Color sub;
  final Color accent;
  final bool expanded;
  final VoidCallback? onToggleDetail;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final title = entry.title.isEmpty ? '포인트' : entry.title;
    final titleSize = nested ? 15.0 : 17.0;
    final pad = nested
        ? const EdgeInsets.fromLTRB(28, 10, 16, 10)
        : const EdgeInsets.fromLTRB(16, 14, 8, 14);

    final row = Padding(
      padding: pad,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: text,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                if (entry.detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.detail,
                    style: TextStyle(
                      color: sub,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  whenLabel,
                  style: TextStyle(
                    color: sub,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              entry.deltaLabel,
              style: TextStyle(
                color: accent,
                fontSize: nested ? 15 : 17,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
          if (onToggleDetail != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: sub,
                ),
              ),
            )
          else if (!nested)
            const SizedBox(width: 8),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        onToggleDetail == null
            ? row
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onToggleDetail,
                  child: row,
                ),
              ),
        if (expanded && entry.children.isNotEmpty)
          ...entry.children.map(
            (child) => _PointHistoryRow(
              entry: child,
              whenLabel:
                  _RecentPointHistoryCardState._whenLabel(child.createdAt),
              text: text,
              sub: sub,
              accent: accent,
              nested: true,
            ),
          ),
      ],
    );
  }
}

/// 과제 `_TodayHomeworkDetailCard` 와 같은 카드 셸·로딩 타이밍.
class _TodayAttendanceDetailCard extends StatelessWidget {
  const _TodayAttendanceDetailCard({
    required this.attendance,
    required this.recent,
    required this.loading,
    required this.error,
    required this.formatTime,
    required this.onRetry,
  });

  final TodayAttendance? attendance;
  final List<RecentAttendanceSession>? recent;
  final bool loading;
  final String? error;
  final String Function(DateTime? dt) formatTime;
  final VoidCallback onRetry;

  static const _cardRadius = 22.0;
  static const _iosBlue = Color(0xFF007AFF);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
    final text = theme.colorScheme.onSurface;
    final subText = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFC6C6C8);

    final hasBody = attendance != null || recent != null;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading && !hasBody)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: YggLoadingIndicator(size: 28)),
            )
          else if (error != null && !hasBody)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                children: [
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: subText),
                  ),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('다시 시도'),
                  ),
                ],
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '오늘',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: subText,
                ),
              ),
            ),
            _AttendanceRow(
              label: '등원',
              value: formatTime(attendance?.arrival),
              recorded: attendance?.arrival != null,
              text: text,
              sub: subText,
              accent: _iosBlue,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Divider(height: 1, thickness: 0.33, color: divider),
            ),
            _AttendanceRow(
              label: '하원',
              value: formatTime(attendance?.departure),
              recorded: attendance?.departure != null,
              text: text,
              sub: subText,
              accent: _iosBlue,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Divider(height: 1, thickness: 0.33, color: divider),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                '최근 10회',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: text,
                ),
              ),
            ),
            if (recent == null && loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: YggLoadingIndicator(size: 28)),
              )
            else
              StudentRecentAttendancePanel(
                sessions: recent ?? const [],
              ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Divider(height: 1, thickness: 0.33, color: divider),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Text(
                '등·하원은 학원 StandbyMe로만 기록돼요.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                  color: subText,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DesiredLevelPick {
  const _DesiredLevelPick(this.topPercent);
  final int? topPercent;
}

class _DesiredLevelSheet extends StatefulWidget {
  const _DesiredLevelSheet({
    required this.options,
    required this.selectedTopPercent,
  });

  final List<StudentLevelOption> options;
  final int? selectedTopPercent;

  @override
  State<_DesiredLevelSheet> createState() => _DesiredLevelSheetState();
}

class _DesiredLevelSheetState extends State<_DesiredLevelSheet> {
  static const _defaultPercent = 40.0;

  /// 실제 상위 %. 슬라이더는 왼쪽=100 · 오른쪽=1 로 뒤집어 표시한다.
  late double _percent;

  List<StudentLevelOption> get _sorted {
    final list = [...widget.options]
      ..sort((a, b) => a.upperPercent.compareTo(b.upperPercent));
    return list;
  }

  double get _sliderValue => (101 - _percent).clamp(1, 100);

  @override
  void initState() {
    super.initState();
    final selected = widget.selectedTopPercent;
    _percent = (selected != null ? selected.toDouble() : _defaultPercent)
        .clamp(1, 100);
  }

  StudentLevelOption? _optionForPercent(double percent) {
    final sorted = _sorted;
    if (sorted.isEmpty) return null;
    for (final opt in sorted) {
      if (percent <= opt.upperPercent) return opt;
    }
    return sorted.last;
  }

  void _save() {
    if (_optionForPercent(_percent) == null) return;
    Navigator.of(context).pop(_DesiredLevelPick(_percent.round()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
    final text = theme.colorScheme.onSurface;
    final sub = text.withValues(alpha: 0.55);
    final current = _optionForPercent(_percent);
    final gradeLabel = current?.displayName ?? '—';
    final percentLabel = StudentLevelOption.formatTopPercent(_percent.round());

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                child: SizedBox(
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        '내 목표',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: text,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SolidCapsuleActionBar(
                          padding: const EdgeInsets.all(8),
                          children: [
                            SolidCapsuleActionButton(
                              tooltip: '닫기',
                              icon: Icons.close_rounded,
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: SolidCapsuleActionBar(
                          padding: const EdgeInsets.all(8),
                          children: [
                            SolidCapsuleActionButton(
                              tooltip: '저장',
                              icon: Icons.check_rounded,
                              onPressed: current == null ? null : _save,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '수능·내신 9등급제 기준이에요. 오른쪽으로 갈수록 상위예요.',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                        color: sub,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      gradeLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        height: 1.05,
                        color: text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      percentLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: sub,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 11,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 20,
                        ),
                      ),
                      child: Slider(
                        min: 1,
                        max: 100,
                        divisions: 99,
                        value: _sliderValue,
                        label: '상위 ${_percent.round()}%',
                        onChanged: (v) => setState(
                          () => _percent = (101 - v).clamp(1, 100),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          Text(
                            '상위 100%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: sub,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '상위 1%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: sub,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.selectedTopPercent != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(
                          const _DesiredLevelPick(null),
                        ),
                        child: const Text(
                          '목표 지우기',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFF554F),
                          ),
                        ),
                      ),
                    ] else
                      const SizedBox(height: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttendanceRow extends StatelessWidget {
  const _AttendanceRow({
    required this.label,
    required this.value,
    required this.recorded,
    required this.text,
    required this.sub,
    required this.accent,
  });

  final String label;
  final String value;
  final bool recorded;
  final Color text;
  final Color sub;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: recorded ? accent : sub,
              fontSize: 17,
              fontWeight: recorded ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
