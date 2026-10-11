import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/think/think_models.dart';
import 'think_style.dart';

Color thinkRoleColor(ThinkRoleId role) => switch (role) {
      ThinkRoleId.lead => kThinkAccent,
      ThinkRoleId.education => kThinkSuccess,
      ThinkRoleId.product => kThinkLink,
      ThinkRoleId.engineering => kThinkBlue,
    };

/// Think 역할별 CustomPainter 아바타(오리지널 형태, kThink* 토큰만 사용).
/// [active]: 이 역할이 지금 답하는 중. 모션 감소 설정이면 고리를 깜빡이지 않고 고정해서 보인다.
/// [semanticsLabel]이 없으면 장식으로 보고 화면 낭독기에서 뺀다(옆 글자가 역할을 말한다).
class ThinkRoleAvatar extends StatelessWidget {
  const ThinkRoleAvatar({super.key, required this.role, this.size = 36, this.active = false, this.semanticsLabel});

  final ThinkRoleId role;
  final double size;
  final bool active;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final face = CustomPaint(size: Size.square(size), painter: _painterFor(role));
    Widget child = SizedBox.square(
      dimension: size,
      child: active
          ? (reduceMotion ? _StaticRing(color: thinkRoleColor(role), child: face) : _PulseRing(color: thinkRoleColor(role), child: face))
          : face,
    );
    final label = semanticsLabel;
    child = label == null ? ExcludeSemantics(child: child) : Semantics(image: true, label: label, child: child);
    return child;
  }

  static CustomPainter _painterFor(ThinkRoleId role) => switch (role) {
        ThinkRoleId.lead => const _LeadAvatarPainter(),
        ThinkRoleId.education => const _EducationAvatarPainter(),
        ThinkRoleId.product => const _ProductAvatarPainter(),
        ThinkRoleId.engineering => const _EngineeringAvatarPainter(),
      };
}

class _StaticRing extends StatelessWidget {
  const _StaticRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
      child: child,
    );
  }
}

class _PulseRing extends StatefulWidget {
  const _PulseRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: widget.color.withValues(alpha: 0.35 + 0.65 * _ctrl.value), width: 2),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 총괄: 원 안의 별.
class _LeadAvatarPainter extends CustomPainter {
  const _LeadAvatarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * 0.42;
    canvas.drawCircle(c, r, Paint()..color = kThinkAccent.withValues(alpha: 0.25));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = kThinkAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final rr = i.isEven ? r * 0.62 : r * 0.26;
      final p = Offset(c.dx + rr * math.cos(a), c.dy + rr * math.sin(a));
      i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
    }
    star.close();
    canvas.drawPath(star, Paint()..color = kThinkAccent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 교육: 펼친 책과 그 위의 점(학생).
class _EducationAvatarPainter extends CustomPainter {
  const _EducationAvatarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    canvas.drawCircle(c, size.shortestSide * 0.42, Paint()..color = kThinkSuccess.withValues(alpha: 0.2));
    final book = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.24, h * 0.42, w * 0.52, h * 0.3), Radius.circular(w * 0.06));
    canvas.drawRRect(book, Paint()..color = kThinkSuccess);
    canvas.drawLine(
      Offset(w * 0.5, h * 0.42),
      Offset(w * 0.5, h * 0.72),
      Paint()
        ..color = kThinkBg
        ..strokeWidth = math.max(1, w * 0.04),
    );
    canvas.drawCircle(Offset(w * 0.5, h * 0.3), w * 0.09, Paint()..color = kThinkText.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 제품: 화면 카드와 그 안의 줄·점.
class _ProductAvatarPainter extends CustomPainter {
  const _ProductAvatarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawCircle(Offset(w / 2, h / 2), size.shortestSide * 0.42, Paint()..color = kThinkLink.withValues(alpha: 0.18));
    final card = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.24, h * 0.28, w * 0.52, h * 0.44), Radius.circular(w * 0.08));
    canvas.drawRRect(card, Paint()..color = kThinkPanel);
    canvas.drawRRect(
      card,
      Paint()
        ..color = kThinkLink
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.04),
    );
    canvas.drawCircle(Offset(w * 0.36, h * 0.42), w * 0.05, Paint()..color = kThinkLink);
    final line = Paint()..color = kThinkSub.withValues(alpha: 0.8);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.45, h * 0.395, w * 0.22, h * 0.05), Radius.circular(w * 0.03)), line);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.32, h * 0.55, w * 0.35, h * 0.05), Radius.circular(w * 0.03)), line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 개발: 꺾쇠 괄호 < / >.
class _EngineeringAvatarPainter extends CustomPainter {
  const _EngineeringAvatarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawCircle(Offset(w / 2, h / 2), size.shortestSide * 0.42, Paint()..color = kThinkBlue.withValues(alpha: 0.22));
    final stroke = Paint()
      ..color = kThinkText
      ..strokeWidth = math.max(1.2, w * 0.06)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.38, h * 0.34)
        ..lineTo(w * 0.26, h * 0.5)
        ..lineTo(w * 0.38, h * 0.66),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.62, h * 0.34)
        ..lineTo(w * 0.74, h * 0.5)
        ..lineTo(w * 0.62, h * 0.66),
      stroke,
    );
    canvas.drawLine(Offset(w * 0.54, h * 0.32), Offset(w * 0.46, h * 0.68), stroke..color = kThinkBlue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
