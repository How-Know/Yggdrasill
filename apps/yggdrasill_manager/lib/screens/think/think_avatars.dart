import 'package:flutter/material.dart';

import '../../services/think/think_models.dart';
import 'think_style.dart';

Color thinkRoleColor(ThinkRoleId role) => switch (role) {
      ThinkRoleId.lead => kThinkAccent,
      ThinkRoleId.education => kThinkSuccess,
      ThinkRoleId.product => kThinkLink,
      ThinkRoleId.engineering => kThinkBlue,
    };

/// Think 부서 캐릭터(14×14 픽셀, kThink* 토큰만 사용). 몸은 같고 부서마다 소품이 다르다.
/// 총괄 왕관, 교육 학사모, 문제 풀이 연필, 개발 헤드폰.
/// [activity]가 답하는 중·Cursor 작업·협의 중이면 움직인다. 모션 감소 설정이면 멈춘 첫 장면만 그린다.
/// [active]는 예전 API(답하는 중)와 같다. [semanticsLabel]이 없으면 장식으로 보고 화면 낭독기에서 뺀다.
class ThinkRoleAvatar extends StatelessWidget {
  const ThinkRoleAvatar({
    super.key,
    required this.role,
    this.size = 36,
    this.active = false,
    this.activity,
    this.semanticsLabel,
  });

  final ThinkRoleId role;
  final double size;
  final bool active;
  final ThinkActivity? activity;
  final String? semanticsLabel;

  ThinkActivity get _activity => activity ?? (active ? ThinkActivity.answering : ThinkActivity.idle);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final a = _activity;
    Widget child = SizedBox.square(
      dimension: size,
      child: a.busy && !reduceMotion
          ? _AnimatedCharacter(role: role, activity: a)
          : CustomPaint(painter: ThinkPixelCharacterPainter(role: role, activity: a, frame: 0)),
    );
    final label = semanticsLabel;
    child = label == null ? ExcludeSemantics(child: child) : Semantics(image: true, label: label, child: child);
    return child;
  }
}

class _AnimatedCharacter extends StatefulWidget {
  const _AnimatedCharacter({required this.role, required this.activity});

  final ThinkRoleId role;
  final ThinkActivity activity;

  @override
  State<_AnimatedCharacter> createState() => _AnimatedCharacterState();
}

class _AnimatedCharacterState extends State<_AnimatedCharacter> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: _period)..repeat();

  Duration get _period => widget.activity == ThinkActivity.coding
      ? const Duration(milliseconds: 500)
      : const Duration(milliseconds: 900);

  @override
  void didUpdateWidget(covariant _AnimatedCharacter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity != widget.activity) {
      _ctrl
        ..duration = _period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => CustomPaint(
        painter: ThinkPixelCharacterPainter(role: widget.role, activity: widget.activity, frame: _ctrl.value < 0.5 ? 0 : 1),
      ),
    );
  }
}

// 기호: B 몸, D 몸 그림자, E 눈, A 소품, L 소품 밝은 부분.
const List<String> _body = [
  '..............',
  '..............',
  '..............',
  '..............',
  '...BBBBBBBB...',
  '...BBBBBBBB...',
  '...BBBBBBBB...',
  '...BBBBBBBB...',
  '.BBBBBBBBBBBB.',
  '...BBBBBBBB...',
  '...DDDDDDDD...',
  '...B.B..B.B...',
  '...B.B..B.B...',
  '..............',
];

const Map<ThinkRoleId, List<String>> _props = {
  ThinkRoleId.lead: [
    '..............',
    '....L.LL.L....',
    '....AAAAAA....',
    '....AAAAAA....',
  ],
  ThinkRoleId.education: [
    '..............',
    '..............',
    '..AAAAAAAAAA..',
    '....AAAAAAL...',
    '..........L...',
  ],
  ThinkRoleId.product: [
    '..............',
    '..............',
    '..............',
    '............L.',
    '............A.',
    '............A.',
    '............A.',
    '............A.',
  ],
  ThinkRoleId.engineering: [
    '..............',
    '..............',
    '....AAAAAA....',
    '...A......A...',
    '..A........A..',
    '..A........A..',
    '..A........A..',
  ],
};

/// 부서 캐릭터 한 장면. [frame] 0·1을 번갈아 그려 움직인다.
class ThinkPixelCharacterPainter extends CustomPainter {
  const ThinkPixelCharacterPainter({required this.role, required this.activity, required this.frame});

  final ThinkRoleId role;
  final ThinkActivity activity;
  final int frame;

  static const int grid = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / grid;
    final origin = Offset((size.width - cell * grid) / 2, (size.height - cell * grid) / 2);
    final body = thinkRoleColor(role);
    final colors = <String, Color>{
      'B': body,
      'D': Color.lerp(body, kThinkBg, 0.4)!,
      'E': kThinkBg,
      'A': role == ThinkRoleId.education ? kThinkPanel : kThinkSub,
      'L': kThinkText,
    };
    final moving = frame == 1;
    final bob = moving && (activity == ThinkActivity.answering || activity == ThinkActivity.consulting) ? -1 : 0;
    final paint = Paint()..isAntiAlias = false;

    void px(int x, int y, String key) {
      final c = colors[key];
      if (c == null) return;
      paint.color = c;
      canvas.drawRect(
        Rect.fromLTWH(origin.dx + x * cell, origin.dy + (y + bob) * cell, cell + 0.01, cell + 0.01),
        paint,
      );
    }

    void layer(List<String> rows) {
      for (var y = 0; y < rows.length; y++) {
        final row = rows[y];
        for (var x = 0; x < row.length && x < grid; x++) {
          if (row[x] != '.') px(x, y, row[x]);
        }
      }
    }

    final rows = [..._body];
    // Cursor 작업: 팔을 번갈아 올려 자판을 치는 모양.
    if (activity == ThinkActivity.coding && moving) {
      rows[7] = '.BBBBBBBBBBBB.';
      rows[8] = '...BBBBBBBB...';
    }
    layer(rows);
    layer(_props[role] ?? const []);

    // 눈: 승인 대기는 위를 보고, 협의 중에는 좌우를 번갈아 본다.
    final eyeY = activity == ThinkActivity.waiting ? 5 : 6;
    final eyeShift = activity == ThinkActivity.consulting ? (moving ? 1 : -1) : 0;
    for (final x in [5, 8]) {
      px(x + eyeShift, eyeY, 'E');
      px(x + eyeShift, eyeY + 1, 'E');
    }
  }

  @override
  bool shouldRepaint(covariant ThinkPixelCharacterPainter old) =>
      old.role != role || old.activity != activity || old.frame != frame;
}
