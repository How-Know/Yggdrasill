import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/student_api.dart';

/// 최근 10회 출결 — 좌측 편차 그래프 + 우측 세션 설명.
/// 과제 펼침 차트·iOS Screen Time 카드와 같은 시각 언어.
class StudentRecentAttendancePanel extends StatelessWidget {
  const StudentRecentAttendancePanel({
    super.key,
    required this.sessions,
  });

  final List<RecentAttendanceSession> sessions;

  static const _iosBlue = Color(0xFF007AFF);
  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  static String summaryLabel(List<RecentAttendanceSession> sessions) {
    final deltas = sessions
        .map((s) => s.deltaMinutes)
        .whereType<int>()
        .toList(growable: false);
    if (deltas.isEmpty) return '등원 기록이 아직 없어요';
    final avg = deltas.reduce((a, b) => a + b) / deltas.length;
    final rounded = avg.round();
    if (rounded == 0) return '대체로 정시에 도착했어요';
    if (rounded < 0) return '평균 ${-rounded}분 일찍 도착';
    return '평균 지각 $rounded분';
  }

  static String _sessionWhen(DateTime dt) {
    final wd = _weekdays[(dt.weekday - 1).clamp(0, 6)];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}월 ${dt.day}일 $wd요일 · $h:$m';
  }

  static String _deltaLabel(RecentAttendanceSession s) {
    final d = s.deltaMinutes;
    if (d == null) return '등원 기록 없음';
    if (d == 0) return '정시';
    if (d < 0) return '${-d}분 일찍';
    if (d > s.latenessThreshold) return '지각 $d분';
    return '$d분 늦음';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = theme.colorScheme.onSurface;
    final subText = text.withValues(alpha: 0.45);
    final track = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : const Color(0xFFE5E5EA);
    final barFill = isDark
        ? Colors.white.withValues(alpha: 0.78)
        : const Color(0xFF3A3A3C);
    final centerLine = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : const Color(0xFFAEAEB2);
    final tick = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFFD1D1D6);

    if (sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Text(
          '최근 출결 기록이 없어요.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: subText),
        ),
      );
    }

    final maxAbs = sessions
        .map((s) => (s.deltaMinutes ?? 0).abs())
        .fold<int>(0, math.max);
    final scale = math.max(15, math.min(maxAbs, 60)).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '최근 평균',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: subText,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            summaryLabel(sessions),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              height: 1.15,
              color: text,
            ),
          ),
          const SizedBox(height: 18),
          for (var i = 0; i < sessions.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _SessionRow(
              index: i + 1,
              session: sessions[i],
              scaleMinutes: scale,
              whenLabel: _sessionWhen(sessions[i].classDateTime),
              deltaLabel: _deltaLabel(sessions[i]),
              text: text,
              subText: subText,
              track: track,
              barFill: barFill,
              lateFill: _iosBlue,
              centerLine: centerLine,
              tick: tick,
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _LegendDot(color: barFill),
              const SizedBox(width: 6),
              Text(
                '일찍',
                style: TextStyle(fontSize: 12, color: subText),
              ),
              const SizedBox(width: 14),
              _LegendDot(color: _iosBlue),
              const SizedBox(width: 6),
              Text(
                '늦음·지각',
                style: TextStyle(fontSize: 12, color: subText),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 10,
                height: 10,
                child: Center(
                  child: Container(
                    width: 1.5,
                    height: 10,
                    color: centerLine,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '정시',
                style: TextStyle(fontSize: 12, color: subText),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.index,
    required this.session,
    required this.scaleMinutes,
    required this.whenLabel,
    required this.deltaLabel,
    required this.text,
    required this.subText,
    required this.track,
    required this.barFill,
    required this.lateFill,
    required this.centerLine,
    required this.tick,
  });

  final int index;
  final RecentAttendanceSession session;
  final double scaleMinutes;
  final String whenLabel;
  final String deltaLabel;
  final Color text;
  final Color subText;
  final Color track;
  final Color barFill;
  final Color lateFill;
  final Color centerLine;
  final Color tick;

  @override
  Widget build(BuildContext context) {
    final delta = session.deltaMinutes;
    final isLateSide = delta != null && delta > 0;
    final accent = isLateSide
        ? (session.isLate ? lateFill : lateFill.withValues(alpha: 0.72))
        : barFill;

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: subText,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: _PunctualityBar(
              deltaMinutes: delta,
              scaleMinutes: scaleMinutes,
              track: track,
              fill: accent,
              centerLine: centerLine,
              tick: tick,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  whenLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    height: 1.15,
                    color: text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  deltaLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.15,
                    color: isLateSide && session.isLate ? lateFill : subText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PunctualityBar extends StatelessWidget {
  const _PunctualityBar({
    required this.deltaMinutes,
    required this.scaleMinutes,
    required this.track,
    required this.fill,
    required this.centerLine,
    required this.tick,
  });

  final int? deltaMinutes;
  final double scaleMinutes;
  final Color track;
  final Color fill;
  final Color centerLine;
  final Color tick;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const barH = 14.0;
        final mid = w / 2;
        final d = deltaMinutes;
        final frac = d == null
            ? 0.0
            : (d.abs() / scaleMinutes).clamp(0.0, 1.0);
        final barW = math.max(d == null || d == 0 ? 0.0 : 3.0, mid * frac);

        return SizedBox(
          width: w,
          height: h,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 트랙
              Container(
                height: barH,
                decoration: BoxDecoration(
                  color: track,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              // 눈금 (5등분)
              CustomPaint(
                size: Size(w, barH),
                painter: _TickPainter(color: tick, divisions: 4),
              ),
              // 막대
              if (d != null && d != 0)
                Positioned(
                  left: d < 0 ? mid - barW : mid,
                  width: barW,
                  child: Container(
                    height: barH,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.horizontal(
                        left: d < 0
                            ? const Radius.circular(4)
                            : Radius.zero,
                        right: d > 0
                            ? const Radius.circular(4)
                            : Radius.zero,
                      ),
                    ),
                  ),
                ),
              // 정시 기준선
              Positioned(
                left: mid - 0.75,
                child: Container(
                  width: 1.5,
                  height: barH + 6,
                  decoration: BoxDecoration(
                    color: centerLine,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter({required this.color, required this.divisions});

  final Color color;
  final int divisions;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 1; i < divisions; i++) {
      final x = size.width * (i / divisions);
      canvas.drawLine(
        Offset(x, 2),
        Offset(x, size.height - 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.divisions != divisions;
}
