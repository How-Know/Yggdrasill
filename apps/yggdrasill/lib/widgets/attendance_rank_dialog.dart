import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/data_manager.dart';
import 'dialog_tokens.dart';
import 'utility_glass_dialog_shell.dart';

Future<void> showAttendanceRankDialog(BuildContext context) {
  return showUtilityGlassDialog(
    context: context,
    title: '출석 순위',
    icon: Icons.leaderboard_rounded,
    maxWidth: 720,
    maxHeight: 720,
    preferredWidth: 680,
    child: const _AttendanceRankDialogBody(),
  );
}

class _AttendanceRankDialogBody extends StatefulWidget {
  const _AttendanceRankDialogBody();

  @override
  State<_AttendanceRankDialogBody> createState() =>
      _AttendanceRankDialogBodyState();
}

class _AttendanceRankDialogBodyState extends State<_AttendanceRankDialogBody> {
  String? _selectedStudentId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        DataManager.instance.studentsNotifier,
        DataManager.instance.attendanceRecordsNotifier,
      ]),
      builder: (context, _) {
        final rows = DataManager.instance.listAttendanceScoresRanked();
        if (rows.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '표시할 재원생이 없습니다.',
                style: TextStyle(color: kDlgTextSub, fontSize: 14),
              ),
            ),
          );
        }

        final points = <_ScorePoint>[];
        for (final row in rows) {
          final totalWeight = _asDouble(row['totalWeight']);
          if (totalWeight <= 0) continue;
          points.add(
            _ScorePoint(
              studentId: (row['studentId'] as String? ?? '').trim(),
              name: (row['studentName'] as String? ?? '').trim(),
              score: _asDouble(row['score100']),
              rank: _asInt(row['rank']) ?? 0,
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const YggDialogSectionHeader(
                icon: Icons.scatter_plot_outlined,
                title: '점수 분포',
              ),
              Container(
                height: 140,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                decoration: BoxDecoration(
                  color: kDlgPanelBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kDlgBorder),
                ),
                child: _ScoreDistributionChart(
                  points: points,
                  selectedStudentId: _selectedStudentId,
                  onSelect: (id) => setState(() => _selectedStudentId = id),
                ),
              ),
              const SizedBox(height: 16),
              const YggDialogSectionHeader(
                icon: Icons.format_list_numbered_rounded,
                title: '순위',
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: kDlgPanelBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kDlgBorder),
                  ),
                  child: ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final studentId =
                          (row['studentId'] as String? ?? '').trim();
                      return _RankTile(
                        row: row,
                        selected: studentId == _selectedStudentId,
                        onTap: () =>
                            setState(() => _selectedStudentId = studentId),
                      );
                    },
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

class _ScorePoint {
  const _ScorePoint({
    required this.studentId,
    required this.name,
    required this.score,
    required this.rank,
  });

  final String studentId;
  final String name;
  final double score;
  final int rank;
}

class _ScoreDistributionChart extends StatelessWidget {
  const _ScoreDistributionChart({
    required this.points,
    required this.selectedStudentId,
    required this.onSelect,
  });

  final List<_ScorePoint> points;
  final String? selectedStudentId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const Center(
        child: Text(
          '출석 기록이 있는 학생이 아직 없어요.',
          style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _layoutBeeswarm(
          points: points,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final hit = _hitTest(layout, details.localPosition);
            if (hit != null) onSelect(hit.studentId);
          },
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _ScoreDistributionPainter(
              layout: layout,
              selectedStudentId: selectedStudentId,
            ),
          ),
        );
      },
    );
  }

  static _BeeswarmLayout _layoutBeeswarm({
    required List<_ScorePoint> points,
    required double width,
    required double height,
  }) {
    const double leftPad = 8;
    const double rightPad = 8;
    const double bottomAxis = 22;
    const double topPad = 8;
    const double radius = 4.5;
    const double gap = 1.2;

    final plotW = math.max(1.0, width - leftPad - rightPad);
    final plotH = math.max(1.0, height - topPad - bottomAxis);
    final centerY = topPad + plotH / 2;

    final sorted = List<_ScorePoint>.from(points)
      ..sort((a, b) {
        final byScore = a.score.compareTo(b.score);
        if (byScore != 0) return byScore;
        return a.studentId.compareTo(b.studentId);
      });

    final placed = <_PlacedDot>[];
    for (final p in sorted) {
      final x = leftPad + (p.score.clamp(0.0, 100.0) / 100.0) * plotW;
      double y = centerY;
      var step = 0;
      while (true) {
        final collide = placed.any((o) {
          final dx = o.offset.dx - x;
          final dy = o.offset.dy - y;
          return math.sqrt(dx * dx + dy * dy) < (radius * 2 + gap);
        });
        if (!collide) break;
        step += 1;
        final dir = step.isOdd ? -1.0 : 1.0;
        final level = ((step + 1) / 2).ceilToDouble();
        y = centerY + dir * level * (radius * 2 + gap);
        if (y < topPad + radius || y > topPad + plotH - radius) {
          y = centerY;
          break;
        }
      }
      placed.add(_PlacedDot(point: p, offset: Offset(x, y), radius: radius));
    }

    return _BeeswarmLayout(
      dots: placed,
      leftPad: leftPad,
      rightPad: rightPad,
      topPad: topPad,
      bottomAxis: bottomAxis,
      plotW: plotW,
      plotH: plotH,
    );
  }

  static _ScorePoint? _hitTest(_BeeswarmLayout layout, Offset pos) {
    _PlacedDot? best;
    var bestDist = double.infinity;
    for (final d in layout.dots) {
      final dist = (d.offset - pos).distance;
      if (dist <= d.radius + 6 && dist < bestDist) {
        best = d;
        bestDist = dist;
      }
    }
    return best?.point;
  }
}

class _PlacedDot {
  const _PlacedDot({
    required this.point,
    required this.offset,
    required this.radius,
  });

  final _ScorePoint point;
  final Offset offset;
  final double radius;
}

class _BeeswarmLayout {
  const _BeeswarmLayout({
    required this.dots,
    required this.leftPad,
    required this.rightPad,
    required this.topPad,
    required this.bottomAxis,
    required this.plotW,
    required this.plotH,
  });

  final List<_PlacedDot> dots;
  final double leftPad;
  final double rightPad;
  final double topPad;
  final double bottomAxis;
  final double plotW;
  final double plotH;
}

class _ScoreDistributionPainter extends CustomPainter {
  _ScoreDistributionPainter({
    required this.layout,
    required this.selectedStudentId,
  });

  final _BeeswarmLayout layout;
  final String? selectedStudentId;

  @override
  void paint(Canvas canvas, Size size) {
    final axisY = layout.topPad + layout.plotH;
    final axisPaint = Paint()
      ..color = kDlgBorder
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(layout.leftPad, axisY),
      Offset(layout.leftPad + layout.plotW, axisY),
      axisPaint,
    );

    final tickPaint = Paint()
      ..color = kDlgTextSub.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    const labelStyle = TextStyle(
      color: kDlgTextSub,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );

    void tick(double score, String label) {
      final x = layout.leftPad + (score / 100.0) * layout.plotW;
      canvas.drawLine(
        Offset(x, axisY),
        Offset(x, axisY + 4),
        tickPaint,
      );
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, axisY + 6));
    }

    tick(0, '0');
    tick(50, '50');
    tick(100, '100');

    // guide line at median if enough points
    if (layout.dots.length >= 2) {
      final scores = layout.dots.map((d) => d.point.score).toList()..sort();
      final mid = scores.length.isOdd
          ? scores[scores.length ~/ 2]
          : (scores[scores.length ~/ 2 - 1] + scores[scores.length ~/ 2]) / 2;
      final mx =
          layout.leftPad + (mid.clamp(0.0, 100.0) / 100.0) * layout.plotW;
      final medianPaint = Paint()
        ..color = kDlgAccent.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(mx, layout.topPad),
        Offset(mx, axisY),
        medianPaint,
      );
    }

    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (final d in layout.dots) {
      final selected = d.point.studentId == selectedStudentId;
      fill.color = selected ? kDlgAccent : kDlgAccent.withValues(alpha: 0.72);
      canvas.drawCircle(d.offset, selected ? d.radius + 1.5 : d.radius, fill);
      if (selected) {
        stroke.color = kDlgText;
        canvas.drawCircle(d.offset, d.radius + 3, stroke);
      }
    }

    if (selectedStudentId != null) {
      for (final d in layout.dots) {
        if (d.point.studentId != selectedStudentId) continue;
        final label =
            '${d.point.name.isEmpty ? '?' : d.point.name} · ${d.point.score.toStringAsFixed(1)}';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              color: kDlgText,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: size.width - 16);
        var lx = d.offset.dx - tp.width / 2;
        lx = lx.clamp(4.0, size.width - tp.width - 4);
        var ly = d.offset.dy - d.radius - tp.height - 6;
        if (ly < 0) ly = d.offset.dy + d.radius + 4;
        final bg = RRect.fromRectAndRadius(
          Rect.fromLTWH(lx - 4, ly - 2, tp.width + 8, tp.height + 4),
          const Radius.circular(6),
        );
        canvas.drawRRect(
          bg,
          Paint()..color = kDlgBg.withValues(alpha: 0.92),
        );
        tp.paint(canvas, Offset(lx, ly));
        break;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ScoreDistributionPainter oldDelegate) {
    return oldDelegate.selectedStudentId != selectedStudentId ||
        oldDelegate.layout.dots.length != layout.dots.length;
  }
}

class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rank = _asInt(row['rank']) ?? 0;
    final name = (row['studentName'] as String? ?? '').trim();
    final score = _asDouble(row['score100']);
    final topPercent = _asDouble(row['topPercent']);
    final totalWeight = _asDouble(row['totalWeight']);
    final absent = _asInt(row['absentCount']) ?? 0;
    final pastPlanned = _asInt(row['pastPlannedAbsentCount']) ?? 0;
    final present = _asInt(row['presentCount']) ?? 0;
    final late = _asInt(row['lateCount']) ?? 0;
    final absenceBand = _asInt(row['absenceBand']) ?? 0;
    final makeupRate = _asDouble(row['makeupRate']);
    final lateRate = _asDouble(row['lateRate']);
    final insufficientEvidence = row['insufficientEvidence'] == true;
    final evidenceWeight = _asDouble(row['evidenceWeight']);
    final weeklyParticipation = _asDouble(row['weeklyParticipation']);
    final subtitleText = totalWeight <= 0
        ? '출석 기록 부족'
        : '${String.fromCharCode(65 + absenceBand)}구간 · '
            '상위 ${topPercent.toStringAsFixed(1)}% · '
            '출석 ${present + late} · 결석 $absent'
            '${pastPlanned > 0 ? ' (미기록 $pastPlanned)' : ''} · '
            '보강 ${(makeupRate * 100).toStringAsFixed(0)}% · '
            '지각 ${(lateRate * 100).toStringAsFixed(0)}% · '
            '주당 ${weeklyParticipation.toStringAsFixed(1)}회'
            '${insufficientEvidence ? ' · 표본 ${evidenceWeight.toStringAsFixed(1)}/8' : ''}';

    return Material(
      color: selected ? kDlgAccent.withValues(alpha: 0.12) : Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        onTap: onTap,
        leading: SizedBox(
          width: 40,
          child: Text(
            '$rank',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: rank <= 3 ? kDlgAccent : kDlgText,
              fontSize: rank <= 3 ? 18 : 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        title: Text(
          name.isEmpty ? '(이름 없음)' : name,
          style: const TextStyle(
            color: kDlgText,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitleText,
          style: const TextStyle(color: kDlgTextSub, fontSize: 12),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: kDlgAccent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDlgAccent.withValues(alpha: 0.45)),
          ),
          child: Text(
            totalWeight <= 0 ? '—' : '${score.toStringAsFixed(1)}점',
            style: const TextStyle(
              color: kDlgText,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
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
