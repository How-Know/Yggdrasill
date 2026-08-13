import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/homework_session.dart';

/// iOS 다이나믹 아일랜드 스타일 상태 영역.
///
/// 과제 타이머가 돌면 공부중(초록), 아니면 휴식중(회색).
class StudentStatusIsland extends StatelessWidget {
  const StudentStatusIsland({super.key});

  static const double height = 36;
  static const double minWidth = 128;

  /// SafeArea + `kToolbarHeight` 중앙 대비 아일랜드 중점 하향 오프셋.
  /// 다른 AppBar 콘텐츠도 이 값으로 Y를 맞춘다.
  /// -4 = 타이틀 바(48)의 top이 상태바 바로 아래 0px에 오는 최소 여백.
  static const double centerOffsetY = -4;

  static const Color _studyingDot = Color(0xFF34C759);
  static const Color _restingDot = Color(0xFF3A3A3C);

  static const TextStyle _labelStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.0,
    letterSpacing: -0.2,
    decoration: TextDecoration.none,
  );

  /// 글리프 실제 ink 박스 기준으로, 알약 가로 중앙선에 문구 시각 중심을 맞춘다.
  static double _inkCenterOffsetY(String label, TextScaler textScaler) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _labelStyle),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    )..layout();

    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    if (boxes.isEmpty) return 0;

    var top = boxes.first.top;
    var bottom = boxes.first.bottom;
    for (final box in boxes) {
      if (box.top < top) top = box.top;
      if (box.bottom > bottom) bottom = box.bottom;
    }
    final inkCenter = (top + bottom) / 2;
    final layoutCenter = painter.height / 2;
    // Center()가 레이아웃 박스를 맞춘 뒤, ink 중심이 레이아웃 중심에 오도록 보정.
    return layoutCenter - inkCenter;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 다이나믹 아일랜드처럼 항상 진한 캡슐 (라이트/다크 공통).
    final fill = isDark ? const Color(0xFF1C1C1E) : const Color(0xFF0B0B0D);
    final border = isDark ? Colors.white10 : Colors.black12;

    return ListenableBuilder(
      listenable: HomeworkSession.instance,
      builder: (context, _) {
        final studying = HomeworkSession.instance.runningGroupId != null;
        final label = studying ? '공부중' : '휴식중';
        final dot = studying ? _studyingDot : _restingDot;
        final inkOffsetY = _inkCenterOffsetY(
          label,
          MediaQuery.textScalerOf(context),
        );

        // 고정 크기: 점=왼쪽, 문구=가운데. 휴식중일 때 오른쪽 모닥불 씬.
        return Semantics(
          label: '학습 상태 $label',
          child: SizedBox(
            width: minWidth,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: border),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned.fill(
                      child: Center(
                        child: Transform.translate(
                          offset: Offset(0, inkOffsetY),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            textHeightBehavior: const TextHeightBehavior(
                              applyHeightToFirstAscent: false,
                              applyHeightToLastDescent: false,
                            ),
                            style: _labelStyle,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: SizedBox(
                          width: 8,
                          height: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: dot,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      // 공부중 씬은 책상 가장자리가 캡슐 곡선에 잘리지 않게
                      // 휴식중보다 4 더 띄운다.
                      right: studying ? 8 : 4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: studying
                            ? const _StudyingHardBadge()
                            : const _RestingCampfireBadge(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

const double _islandSceneLogical = 64;
const double _islandSceneDisplay = 22;

/// 휴식/공부 씬 공통 인물 팔레트 (연속성).
const Color _islandSkin = Color(0xFFE8E8ED);
const Color _islandHair = Color(0xFFC7C7CC);
const Color _islandPants = Color(0xFF8E8E93);

/// 64×64 논리 캔버스 → 아일랜드 높이 안에 맞게 축소.
///
/// 정면으로 앉아 책상에 글을 쓴다. 필기는 짧은 획을 긋고 펜을 들어
/// 다음 줄로 가는 루프.
class _StudyingHardBadge extends StatefulWidget {
  const _StudyingHardBadge();

  @override
  State<_StudyingHardBadge> createState() => _StudyingHardBadgeState();
}

class _StudyingHardBadgeState extends State<_StudyingHardBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _islandSceneDisplay,
      height: _islandSceneDisplay,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return CustomPaint(
              size: const Size.square(_islandSceneDisplay),
              painter: _StudyingHardPainter(t: _ctrl.value),
            );
          },
        ),
      ),
    );
  }
}

class _StudyingHardPainter extends CustomPainter {
  _StudyingHardPainter({required this.t});

  final double t;

  /// 정면 노트 위에서 한 사이클에 두 줄.
  /// 각 줄은 긋기(0–0.72) → 들어올림(0.72–1).
  static Offset _penOnPage(double u) {
    const line0y = 45.6;
    const line1y = 48.8;
    const startX = 22.0;
    const strokeW = 20.0;
    final line = u < 0.5 ? 0 : 1;
    final local = ((u < 0.5 ? u : u - 0.5) / 0.5).clamp(0.0, 1.0);
    final writing = local < 0.72;
    final stroke = writing ? (local / 0.72) : 1.0;
    final x = startX + stroke * strokeW;
    final y = (line == 0 ? line0y : line1y) +
        (writing ? math.sin(stroke * math.pi * 3) * 0.55 : -2.2);
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / _islandSceneLogical;
    canvas.save();
    canvas.scale(s, s);

    final bob = math.sin(t * math.pi * 2) * 0.35;
    final pen = _penOnPage(t);

    final skin = Paint()..color = _islandSkin;
    final hair = Paint()..color = _islandHair;
    final pants = Paint()
      ..color = _islandPants
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    final armPaint = Paint()
      ..color = _islandSkin
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    // 1) 사람 몸 — 책상 뒤에 앉은 정면.
    canvas.save();
    canvas.translate(0, bob);

    canvas.drawLine(const Offset(28, 42), const Offset(25, 58), pants);
    canvas.drawLine(const Offset(36, 42), const Offset(39, 58), pants);

    final torso = Path()
      ..moveTo(25, 24)
      ..quadraticBezierTo(23, 34, 25, 46)
      ..lineTo(39, 46)
      ..quadraticBezierTo(41, 34, 39, 24)
      ..close();
    canvas.drawPath(torso, skin);

    canvas.drawCircle(const Offset(32, 17.5), 7.0, skin);
    final hairPath = Path()
      ..moveTo(25.5, 16)
      ..quadraticBezierTo(26.5, 8.5, 32, 8)
      ..quadraticBezierTo(38.5, 8.5, 38.5, 16)
      ..quadraticBezierTo(36, 13, 32, 13.5)
      ..quadraticBezierTo(28, 13, 25.5, 16.5)
      ..close();
    canvas.drawPath(hairPath, hair);
    canvas.restore();

    // 2) 책상 — 정면에서 허리 아래를 가린다.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(4, 50, 56, 10),
        const Radius.circular(2.5),
      ),
      Paint()..color = const Color(0xFFC4A574),
    );
    canvas.drawLine(
      const Offset(5, 51.3),
      const Offset(59, 51.3),
      Paint()
        ..color = const Color(0xFFE8D5B5)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );

    // 3) 노트 — 책상 위, 정면 사각형.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(16, 41, 32, 12),
        const Radius.circular(1.8),
      ),
      Paint()..color = const Color(0xFFF5F5F7),
    );

    final inkDone = Paint()
      ..color = const Color(0xFF3A3A3C)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final done = Path()..moveTo(19, 44.2);
    for (var k = 1; k <= 12; k++) {
      final p = k / 12.0;
      done.lineTo(19 + p * 26, 44.2 + math.sin(p * math.pi * 4) * 0.6);
    }
    canvas.drawPath(done, inkDone);

    final inkLive = Paint()
      ..color = const Color(0xFF1C1C1E)
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final live = Path();
    const samples = 56;
    var started = false;
    for (var i = 0; i <= samples; i++) {
      final u = i / samples;
      if (u > t) break;
      final local = ((u < 0.5 ? u : u - 0.5) / 0.5);
      if (local >= 0.72) {
        started = false;
        continue;
      }
      final pt = _penOnPage(u);
      if (!started) {
        live.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        live.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(live, inkLive);

    // 4) 팔·펜 — 책상 앞으로 나와 노트에 글을 쓴다.
    canvas.save();
    canvas.translate(0, bob);

    canvas.drawLine(const Offset(26, 28), const Offset(22, 42), armPaint);
    canvas.drawCircle(const Offset(21.5, 43.2), 2.1, skin);

    const shoulder = Offset(38, 27);
    final elbow = Offset(40.5 + (pen.dx - 32) * 0.08, 35);
    final hand = Offset(pen.dx + 0.4, pen.dy - 1.4);
    canvas.drawLine(shoulder, elbow, armPaint);
    canvas.drawLine(elbow, hand, armPaint);
    canvas.drawCircle(hand, 2.3, skin);

    canvas.drawLine(
      Offset(pen.dx + 2.2, pen.dy - 7.2),
      Offset(pen.dx, pen.dy),
      Paint()
        ..color = const Color(0xFFFFD60A)
        ..strokeWidth = 2.3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(pen.dx, pen.dy),
      Offset(pen.dx - 0.2, pen.dy + 2.0),
      Paint()
        ..color = const Color(0xFF34C759)
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round,
    );

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StudyingHardPainter oldDelegate) =>
      oldDelegate.t != t;
}

/// 64×64 논리 캔버스 → 아일랜드 높이 안에 맞게 축소. 모닥불+쉬는 사람 + 루프 모션.
class _RestingCampfireBadge extends StatefulWidget {
  const _RestingCampfireBadge();

  @override
  State<_RestingCampfireBadge> createState() => _RestingCampfireBadgeState();
}

class _RestingCampfireBadgeState extends State<_RestingCampfireBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _islandSceneDisplay,
      height: _islandSceneDisplay,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return CustomPaint(
              size: const Size.square(_islandSceneDisplay),
              painter: _RestingCampfirePainter(t: _ctrl.value),
            );
          },
        ),
      ),
    );
  }
}

class _RestingCampfirePainter extends CustomPainter {
  _RestingCampfirePainter({required this.t});

  /// 0..1 루프.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // 64×64 논리 좌표계로 그린 뒤 표시 크기로 스케일.
    final s = size.width / _islandSceneLogical;
    canvas.save();
    canvas.scale(s, s);

    final flicker = 0.5 + 0.5 * math.sin(t * math.pi * 2);
    final flicker2 = 0.5 + 0.5 * math.sin(t * math.pi * 2 + 1.7);
    final breath = math.sin(t * math.pi * 2) * 1.2;

    // --- 모닥불 (오른쪽) ---
    final logPaint = Paint()
      ..color = const Color(0xFF6B4A2B)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(38, 48), const Offset(54, 44), logPaint);
    canvas.drawLine(const Offset(40, 52), const Offset(56, 48), logPaint);

    // 불꽃
    final flameCenter = Offset(47, 40 - flicker * 2);
    final outer = Paint()
      ..color = Color.lerp(
        const Color(0xFFFF6B2C),
        const Color(0xFFFF9F1A),
        flicker,
      )!
          .withValues(alpha: 0.95);
    final inner = Paint()
      ..color = Color.lerp(
        const Color(0xFFFFD166),
        const Color(0xFFFFF3C4),
        flicker2,
      )!;

    final flamePath = Path()
      ..moveTo(flameCenter.dx, flameCenter.dy - 10 - flicker * 3)
      ..cubicTo(
        flameCenter.dx + 7 + flicker,
        flameCenter.dy - 2,
        flameCenter.dx + 6,
        flameCenter.dy + 6,
        flameCenter.dx,
        flameCenter.dy + 8,
      )
      ..cubicTo(
        flameCenter.dx - 6,
        flameCenter.dy + 6,
        flameCenter.dx - 7 - flicker2,
        flameCenter.dy - 2,
        flameCenter.dx,
        flameCenter.dy - 10 - flicker * 3,
      );
    canvas.drawPath(flamePath, outer);

    final innerPath = Path()
      ..moveTo(flameCenter.dx, flameCenter.dy - 5 - flicker2 * 2)
      ..cubicTo(
        flameCenter.dx + 3.5,
        flameCenter.dy,
        flameCenter.dx + 3,
        flameCenter.dy + 4,
        flameCenter.dx,
        flameCenter.dy + 5,
      )
      ..cubicTo(
        flameCenter.dx - 3,
        flameCenter.dy + 4,
        flameCenter.dx - 3.5,
        flameCenter.dy,
        flameCenter.dx,
        flameCenter.dy - 5 - flicker2 * 2,
      );
    canvas.drawPath(innerPath, inner);

    // 불티
    final sparkPaint = Paint()..color = const Color(0xFFFFE08A);
    for (var i = 0; i < 3; i++) {
      final phase = (t + i * 0.27) % 1.0;
      final sx = 44.0 + i * 3.5 + math.sin(phase * math.pi * 2 + i) * 2;
      final sy = 38.0 - phase * 14;
      final a = (1.0 - phase).clamp(0.0, 1.0);
      sparkPaint.color = const Color(0xFFFFE08A).withValues(alpha: a * 0.9);
      canvas.drawCircle(Offset(sx, sy), 1.1 + flicker * 0.4, sparkPaint);
    }

    // --- 앉아서 쉬는 사람 (왼편, 불을 보며 무릎 끌어안고 앉은 포즈) ---
    canvas.save();
    canvas.translate(0, breath);

    final skin = Paint()..color = _islandSkin;
    final hair = Paint()..color = _islandHair;
    final pants = Paint()
      ..color = _islandPants
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    final armPaint = Paint()
      ..color = _islandSkin
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;

    // 지면/엉덩이 받침 (앉아 있음 강조)
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(20, 52), width: 18, height: 5),
      Paint()..color = const Color(0x33FFFFFF),
    );

    // 몸통 — 살짝 앞으로 숙인 앉은 자세
    final torso = Path()
      ..moveTo(16, 30)
      ..quadraticBezierTo(14, 38, 17, 46)
      ..lineTo(26, 46)
      ..quadraticBezierTo(28, 36, 24, 29)
      ..close();
    canvas.drawPath(torso, skin);

    // 머리 (불 쪽으로 살짝)
    canvas.drawCircle(const Offset(22, 23), 6.0, skin);
    // 머리숱
    final hairPath = Path()
      ..moveTo(17, 21)
      ..quadraticBezierTo(18, 15, 24, 16)
      ..quadraticBezierTo(28, 18, 26, 23)
      ..quadraticBezierTo(22, 20, 17, 22)
      ..close();
    canvas.drawPath(hairPath, hair);

    // 무릎 올린 다리 (앉아서 쉬는 실루엣)
    // 허벅지 → 무릎
    canvas.drawLine(const Offset(20, 44), const Offset(30, 38), pants);
    // 정강이 → 발
    canvas.drawLine(const Offset(30, 38), const Offset(28, 50), pants);
    // 반대쪽 다리(접혀 보임)
    canvas.drawLine(const Offset(18, 45), const Offset(12, 50), pants);

    // 팔 — 무릎을 감싸 안은 포즈
    canvas.drawLine(const Offset(24, 33), const Offset(30, 37), armPaint);
    canvas.drawLine(const Offset(18, 34), const Offset(28, 39), armPaint);
    // 손/팔꿈치 덩어리
    canvas.drawCircle(const Offset(30, 38), 2.2, skin);

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RestingCampfirePainter oldDelegate) =>
      oldDelegate.t != t;
}

/// 아일랜드와 **동일한** 세로 슬롯 (SafeArea + 툴바 56 + centerOffsetY).
/// 이 슬롯 안에서 CrossAxisAlignment.center / Center 한 위젯은 아일랜드 중점과 Y가 같다.
class StudentStatusIslandToolbarSlot extends StatelessWidget {
  const StudentStatusIslandToolbarSlot({
    super.key,
    required this.child,
    this.ignorePointer = false,
  });

  final Widget child;
  final bool ignorePointer;

  /// AppBar preferredSize 높이 = 상태바 + 툴바 + 오프셋 보정.
  /// centerOffsetY가 음수면 콘텐츠가 올라간 만큼 슬롯 아래 여백도 줄인다.
  static double preferredHeight(BuildContext context) =>
      MediaQuery.paddingOf(context).top +
      kToolbarHeight +
      StudentStatusIsland.centerOffsetY * 2;

  @override
  Widget build(BuildContext context) {
    final slot = SafeArea(
      bottom: false,
      child: SizedBox(
        height: kToolbarHeight,
        child: Transform.translate(
          offset: const Offset(0, StudentStatusIsland.centerOffsetY),
          child: child,
        ),
      ),
    );
    return ignorePointer ? IgnorePointer(child: slot) : slot;
  }
}

/// Navigator 위에 올려 탭·push 전환에도 같은 자리에 유지한다.
class StudentStatusIslandHost extends StatelessWidget {
  const StudentStatusIslandHost({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final loggedIn = Supabase.instance.client.auth.currentSession != null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child!,
            if (loggedIn)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: StudentStatusIslandToolbarSlot(
                  ignorePointer: true,
                  child: Center(child: StudentStatusIsland()),
                ),
              ),
          ],
        );
      },
    );
  }
}
