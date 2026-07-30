import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import '../widgets/student_attendance_score_card.dart';
import '../widgets/student_page_title.dart';

/// 출결 점수 + 오늘 출결 조회. 프로필·테마·로그아웃은 상단 계정 시트에서 처리.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  TodayAttendance? _attendance;
  AttendanceScoreInfo? _score;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        StudentApi.instance.todayAttendance(),
        StudentApi.instance.getAttendanceScore(),
      ]);
      if (!mounted) return;
      setState(() {
        _attendance = results[0] as TodayAttendance?;
        _score = results[1] as AttendanceScoreInfo?;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '정보를 불러오지 못했어요.\n$e';
        _loading = false;
      });
    }
  }

  static String _formatTime(DateTime? dt) {
    if (dt == null) return '기록 없음';
    return '${dt.hour}:${'${dt.minute}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final text = Theme.of(context).colorScheme.onSurface;
    final sub = text.withValues(alpha: 0.55);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE5E5EA);
    final att = _attendance;
    final score = _score;

    return StudentCollapsingTitlePage(
      title: '내 정보',
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      bodyBuilder: (context, topInset, bottomInset) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, bottomInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Text(_error!, textAlign: TextAlign.center),
                )
              else if (_loading && att == null && score == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: YggLoadingIndicator(size: 32)),
                )
              else ...[
                StudentAttendanceScoreCard(
                  score100: score?.score100,
                  subtitle: score == null
                      ? (_loading
                          ? '출석 점수를 불러오는 중…'
                          : '출석 점수를 불러오지 못했어요')
                      : score.subtitle,
                ),
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
                _ProfileGroupedCard(
                  brightness: brightness,
                  children: [
                    _AttendanceRow(
                      label: '등원',
                      value: _formatTime(att?.arrival),
                      recorded: att?.arrival != null,
                      text: text,
                      sub: sub,
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 24,
                      endIndent: 24,
                      color: divider,
                    ),
                    _AttendanceRow(
                      label: '하원',
                      value: _formatTime(att?.departure),
                      recorded: att?.departure != null,
                      text: text,
                      sub: sub,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '등·하원은 학원 StandbyMe로만 기록돼요.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                    color: sub,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ProfileGroupedCard extends StatelessWidget {
  const _ProfileGroupedCard({
    required this.brightness,
    required this.children,
  });

  final Brightness brightness;
  final List<Widget> children;

  static const _radius = 28.0;
  static const _groupDark = Color(0xFF2C2C2E);

  @override
  Widget build(BuildContext context) {
    final fill =
        brightness == Brightness.dark ? _groupDark : Colors.white;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
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
  });

  final String label;
  final String value;
  final bool recorded;
  final Color text;
  final Color sub;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
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
              color: recorded ? YggGlassTokens.confirmActionColor : sub,
              fontSize: 17,
              fontWeight: recorded ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
