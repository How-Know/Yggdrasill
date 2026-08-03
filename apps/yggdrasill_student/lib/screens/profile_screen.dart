import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
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

  bool _expanded = false;
  TodayAttendance? _attendance;
  List<RecentAttendanceSession>? _recent;
  bool _loadingAttendance = false;
  String? _attendanceError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadScore());
  }

  Future<void> refresh() async {
    await _loadScore();
    if (_expanded) {
      await _ensureAttendanceLoaded(force: true);
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

  Future<void> _toggle() async {
    final next = !_expanded;
    setState(() => _expanded = next);
    if (next) await _ensureAttendanceLoaded(force: true);
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
      final results = await Future.wait([
        StudentApi.instance.todayAttendance(),
        StudentApi.instance.listRecentAttendance(limit: 10),
      ]);
      if (!mounted) return;
      setState(() {
        _attendance = results[0] as TodayAttendance;
        _recent = results[1] as List<RecentAttendanceSession>;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudentAttendanceScoreCard(
          score100: score?.score100,
          subtitle: score == null
              ? (_loadingScore ? '출석 점수를 불러오는 중…' : '출석 점수를 불러오지 못했어요')
              : score.subtitle,
          onTap: () => unawaited(_toggle()),
          showInfoIcon: true,
          infoFilled: _expanded,
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
