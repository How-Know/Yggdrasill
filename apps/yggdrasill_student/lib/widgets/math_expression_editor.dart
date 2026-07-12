import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

/// 구조식 수식 에디터.
///
/// 위쪽 미리보기 창에 현재 수식이 2D로 렌더되고, 분수/루트/거듭제곱은
/// 빈 네모(슬롯)로 삽입된다. 슬롯을 터치해 커서를 옮기고 키패드로 채운다.
/// 완성된 수식은 서버 채점 엔진과 호환되는 선형 표기로 직렬화된다.
///   분수 → (a)/(b)   루트 → √(x)   n제곱근 → √[n](x)   거듭제곱 → (a)^(n)
class MathExpressionEditor extends StatefulWidget {
  const MathExpressionEditor({
    super.key,
    this.initialLinear = '',
    required this.onChanged,
  });

  /// 기존 답(선형 표기)을 트리로 복원해 이어서 편집.
  final String initialLinear;
  final ValueChanged<String> onChanged;

  @override
  State<MathExpressionEditor> createState() => MathExpressionEditorState();
}

// ---------------------------------------------------------------------------
// 수식 트리 모델
// ---------------------------------------------------------------------------

/// 수평으로 나열되는 원자들의 목록. (= 하나의 입력 슬롯)
class _Seq {
  final List<_Atom> atoms = <_Atom>[];
  _Atom? parent; // 이 슬롯을 소유한 구조 원자
}

sealed class _Atom {
  _Seq? owner;
}

/// 일반 문자 (숫자/연산자/변수/단위 문자 등)
class _CharAtom extends _Atom {
  _CharAtom(this.char, {this.repeating = false});
  final String char;

  /// 순환소수 점(ẋ) 여부 — 직렬화 시 결합 점(U+0307)을 붙인다.
  final bool repeating;
}

class _FracAtom extends _Atom {
  _FracAtom() {
    num.parent = this;
    den.parent = this;
  }
  final _Seq num = _Seq();
  final _Seq den = _Seq();
}

class _SqrtAtom extends _Atom {
  _SqrtAtom({bool withIndex = false}) : index = withIndex ? _Seq() : null {
    body.parent = this;
    index?.parent = this;
  }
  final _Seq body = _Seq();

  /// n제곱근 인덱스 (null이면 제곱근)
  final _Seq? index;
}

/// 거듭제곱: 밑과 지수 모두 슬롯.
class _PowAtom extends _Atom {
  _PowAtom() {
    base.parent = this;
    exp.parent = this;
  }
  final _Seq base = _Seq();
  final _Seq exp = _Seq();
}

// ---------------------------------------------------------------------------

class MathExpressionEditorState extends State<MathExpressionEditor> {
  final _Seq _root = _Seq();
  late _Seq _cursorSeq;
  late int _cursorIndex;

  @override
  void initState() {
    super.initState();
    _cursorSeq = _root;
    _cursorIndex = 0;
    if (widget.initialLinear.isNotEmpty) {
      _parseInto(_root, widget.initialLinear);
      _cursorIndex = _root.atoms.length;
    }
  }

  // ------------------------------------------------------------- 직렬화/파싱

  String serialize() => _serializeSeq(_root);

  /// 외부(테스트/화면)에서 현재 수식의 선형 표기를 읽는다.
  String toLinear() => serialize();

  static String _serializeSeq(_Seq seq) {
    final sb = StringBuffer();
    for (final atom in seq.atoms) {
      switch (atom) {
        case _CharAtom c:
          sb.write(c.repeating ? '${c.char}\u0307' : c.char);
        case _FracAtom f:
          sb.write('(${_serializeSeq(f.num)})/(${_serializeSeq(f.den)})');
        case _SqrtAtom s:
          final idx = s.index;
          sb.write(
            idx == null
                ? '√(${_serializeSeq(s.body)})'
                : '√[${_serializeSeq(idx)}](${_serializeSeq(s.body)})',
          );
        case _PowAtom p:
          // 밑이 단일 문자면 괄호 생략: x^(2), 아니면 (x+1)^(2)
          final base = _serializeSeq(p.base);
          final needsParen = base.length != 1;
          sb.write(
            '${needsParen ? '($base)' : base}^(${_serializeSeq(p.exp)})',
          );
      }
    }
    return sb.toString();
  }

  /// 선형 표기를 최대한 트리로 복원.
  /// `(a)/(b)`, `(a)^(b)`, `√(x)`, `√[n](x)`, `x^(n)` 패턴 인식.
  static void _parseInto(_Seq seq, String input) {
    var i = 0;

    int findClose(String s, int open) {
      var depth = 0;
      for (var j = open; j < s.length; j++) {
        if (s[j] == '(') depth++;
        if (s[j] == ')') {
          depth--;
          if (depth == 0) return j;
        }
      }
      return -1;
    }

    void add(_Atom a) {
      a.owner = seq;
      seq.atoms.add(a);
    }

    while (i < input.length) {
      final c = input[i];
      if (c == '√') {
        // √[n](x) 또는 √(x)
        var pos = i + 1;
        String? idxStr;
        if (pos < input.length && input[pos] == '[') {
          final closeIdx = input.indexOf(']', pos);
          if (closeIdx > 0) {
            idxStr = input.substring(pos + 1, closeIdx);
            pos = closeIdx + 1;
          }
        }
        if (pos < input.length && input[pos] == '(') {
          final close = findClose(input, pos);
          if (close > 0) {
            final atom = _SqrtAtom(withIndex: idxStr != null);
            if (idxStr != null) _parseInto(atom.index!, idxStr);
            _parseInto(atom.body, input.substring(pos + 1, close));
            add(atom);
            i = close + 1;
            continue;
          }
        }
      }
      if (c == '^' && i + 1 < input.length && input[i + 1] == '(') {
        // 밑 없는 ^(n) — 직전 원자를 밑으로 흡수
        final close = findClose(input, i + 1);
        if (close > 0) {
          final atom = _PowAtom();
          if (seq.atoms.isNotEmpty) {
            final base = seq.atoms.removeLast();
            base.owner = atom.base;
            atom.base.atoms.add(base);
          }
          _parseInto(atom.exp, input.substring(i + 2, close));
          add(atom);
          i = close + 1;
          continue;
        }
      }
      if (c == '(') {
        final close = findClose(input, i);
        if (close > 0 && close + 2 < input.length && input[close + 2] == '(') {
          final op = input[close + 1];
          if (op == '/' || op == '^') {
            final rightClose = findClose(input, close + 2);
            if (rightClose > 0) {
              if (op == '/') {
                final atom = _FracAtom();
                _parseInto(atom.num, input.substring(i + 1, close));
                _parseInto(atom.den, input.substring(close + 3, rightClose));
                add(atom);
              } else {
                final atom = _PowAtom();
                _parseInto(atom.base, input.substring(i + 1, close));
                _parseInto(atom.exp, input.substring(close + 3, rightClose));
                add(atom);
              }
              i = rightClose + 1;
              continue;
            }
          }
        }
      }
      // 결합 순환점: 숫자 + U+0307
      if (i + 1 < input.length && input[i + 1] == '\u0307') {
        add(_CharAtom(c, repeating: true));
        i += 2;
        continue;
      }
      add(_CharAtom(c));
      i++;
    }
  }

  // ------------------------------------------------------------------ 편집

  void _notify() => widget.onChanged(serialize());

  void _insertAtom(_Atom atom, _Seq firstSlot) {
    setState(() {
      atom.owner = _cursorSeq;
      _cursorSeq.atoms.insert(_cursorIndex, atom);
      _cursorIndex++;
      _cursorSeq = firstSlot;
      _cursorIndex = 0;
    });
    _notify();
  }

  void insertText(String token) {
    setState(() {
      for (final ch in token.characters) {
        final atom = _CharAtom(ch);
        atom.owner = _cursorSeq;
        _cursorSeq.atoms.insert(_cursorIndex, atom);
        _cursorIndex++;
      }
    });
    _notify();
  }

  void insertFraction() {
    final atom = _FracAtom();
    _insertAtom(atom, atom.num);
  }

  void insertSqrt() {
    final atom = _SqrtAtom();
    _insertAtom(atom, atom.body);
  }

  /// n제곱근 (세제곱근·네제곱근 등) — 인덱스 슬롯부터 입력.
  void insertNthRoot() {
    final atom = _SqrtAtom(withIndex: true);
    _insertAtom(atom, atom.index!);
  }

  /// 거듭제곱 — 커서 직전 원자가 있으면 밑으로 흡수, 없으면 빈 밑 네모.
  void insertPower() {
    final atom = _PowAtom();
    if (_cursorIndex > 0) {
      final prev = _cursorSeq.atoms[_cursorIndex - 1];
      if (prev is _CharAtom || prev is _SqrtAtom || prev is _FracAtom) {
        setState(() {
          _cursorSeq.atoms.removeAt(_cursorIndex - 1);
          _cursorIndex--;
          prev.owner = atom.base;
          atom.base.atoms.add(prev);
        });
        _insertAtom(atom, atom.exp);
        return;
      }
    }
    _insertAtom(atom, atom.base);
  }

  /// 순환소수 점: 직전 문자가 숫자면 점을 토글한다.
  void insertRepeatingDot() {
    if (_cursorIndex == 0) return;
    final prev = _cursorSeq.atoms[_cursorIndex - 1];
    if (prev is! _CharAtom || !RegExp(r'^\d$').hasMatch(prev.char)) return;
    setState(() {
      final replaced = _CharAtom(prev.char, repeating: !prev.repeating);
      replaced.owner = _cursorSeq;
      _cursorSeq.atoms[_cursorIndex - 1] = replaced;
    });
    _notify();
  }

  void backspace() {
    setState(() {
      if (_cursorIndex > 0) {
        _cursorSeq.atoms.removeAt(_cursorIndex - 1);
        _cursorIndex--;
      } else {
        // 슬롯 맨 앞에서 backspace → 슬롯이 모두 비어 있으면 구조 자체 제거
        final parentAtom = _cursorSeq.parent;
        if (parentAtom == null) return;
        final ownerSeq = parentAtom.owner;
        if (ownerSeq == null) return;
        final structEmpty = switch (parentAtom) {
          _FracAtom f => f.num.atoms.isEmpty && f.den.atoms.isEmpty,
          _SqrtAtom s =>
            s.body.atoms.isEmpty && (s.index?.atoms.isEmpty ?? true),
          _PowAtom p => p.base.atoms.isEmpty && p.exp.atoms.isEmpty,
          _ => true,
        };
        final idx = ownerSeq.atoms.indexOf(parentAtom);
        if (idx < 0) return;
        if (structEmpty) ownerSeq.atoms.removeAt(idx);
        _cursorSeq = ownerSeq;
        _cursorIndex = idx;
      }
    });
    _notify();
  }

  void clearAll() {
    setState(() {
      _root.atoms.clear();
      _cursorSeq = _root;
      _cursorIndex = 0;
    });
    _notify();
  }

  void _placeCursor(_Seq seq, int index) {
    setState(() {
      _cursorSeq = seq;
      _cursorIndex = index;
    });
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      // 빈 영역 터치 → 맨 끝으로 커서 이동
      behavior: HitTestBehavior.opaque,
      onTap: () => _placeCursor(_root, _root.atoms.length),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 68),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: YggGlassTokens.confirmActionColor.withValues(alpha: 0.45),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSeq(context, _root, fontSize: 26),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _atomStyle(ThemeData theme, double fontSize) =>
      theme.textTheme.titleLarge!.copyWith(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        height: 1.15,
      );

  Widget _buildSeq(BuildContext context, _Seq seq, {required double fontSize}) {
    final theme = Theme.of(context);
    final children = <Widget>[];

    Widget cursorBar() => _CursorBar(height: fontSize + 6);

    Widget tapZone(int index, {double width = 6}) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _placeCursor(seq, index),
        child: SizedBox(width: width, height: fontSize + 10),
      );
    }

    final showCursorHere = identical(seq, _cursorSeq);

    if (seq.atoms.isEmpty) {
      // 빈 슬롯: 점선 네모
      return GestureDetector(
        onTap: () => _placeCursor(seq, 0),
        child: Container(
          width: fontSize * 0.85,
          height: fontSize * 1.1,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: showCursorHere
                  ? YggGlassTokens.confirmActionColor
                  : theme.hintColor.withValues(alpha: 0.55),
              width: showCursorHere ? 2 : 1.2,
            ),
          ),
          child: showCursorHere && _cursorIndex == 0
              ? Center(child: cursorBar())
              : null,
        ),
      );
    }

    children.add(tapZone(0));
    if (showCursorHere && _cursorIndex == 0) children.add(cursorBar());

    for (var i = 0; i < seq.atoms.length; i++) {
      final atom = seq.atoms[i];
      children.add(GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _placeCursor(seq, i + 1),
        child: _buildAtom(context, atom, fontSize: fontSize),
      ));
      children.add(tapZone(i + 1));
      if (showCursorHere && _cursorIndex == i + 1) children.add(cursorBar());
    }

    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _buildAtom(
    BuildContext context,
    _Atom atom, {
    required double fontSize,
  }) {
    final theme = Theme.of(context);
    final textStyle = _atomStyle(theme, fontSize);
    final lineColor = theme.textTheme.bodyLarge?.color ?? Colors.black;

    switch (atom) {
      case _CharAtom c:
        if (!c.repeating) return Text(c.char, style: textStyle);
        // 순환소수: 결합 문자 대신 점을 직접 그려 폰트 이질감 제거
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: fontSize * 0.14,
              height: fontSize * 0.14,
              margin: EdgeInsets.only(bottom: fontSize * 0.06),
              decoration: BoxDecoration(
                color: lineColor,
                shape: BoxShape.circle,
              ),
            ),
            Text(c.char, style: textStyle),
          ],
        );
      case _FracAtom f:
        final childSize = fontSize * 0.82;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSeq(context, f.num, fontSize: childSize),
              Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                height: 1.6,
                constraints: BoxConstraints(minWidth: fontSize * 0.9),
                color: lineColor,
              ),
              _buildSeq(context, f.den, fontSize: childSize),
            ],
          ),
        );
      case _SqrtAtom s:
        final body = Padding(
          // 루트 기호(hook)와 윗줄이 차지할 공간
          padding: EdgeInsets.only(
            left: fontSize * 0.62,
            top: fontSize * 0.28,
            right: 3,
            bottom: 2,
          ),
          child: _buildSeq(context, s.body, fontSize: fontSize * 0.92),
        );
        final radical = CustomPaint(
          painter: _RadicalPainter(
            color: lineColor,
            hookWidth: fontSize * 0.55,
            strokeWidth: fontSize * 0.07,
          ),
          child: body,
        );
        final idx = s.index;
        if (idx == null) return radical;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: EdgeInsets.only(left: fontSize * 0.30),
              child: radical,
            ),
            Positioned(
              left: 0,
              top: -fontSize * 0.12,
              child: _buildSeq(context, idx, fontSize: fontSize * 0.5),
            ),
          ],
        );
      case _PowAtom p:
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: fontSize * 0.34),
              child: _buildSeq(context, p.base, fontSize: fontSize),
            ),
            _buildSeq(context, p.exp, fontSize: fontSize * 0.62),
          ],
        );
    }
  }
}

/// 루트 기호를 직접 그린다 — 글리프가 잘리는 문제 없이 본문 높이에 맞춰
/// 갈고리와 윗줄이 한 획으로 이어진다.
class _RadicalPainter extends CustomPainter {
  const _RadicalPainter({
    required this.color,
    required this.hookWidth,
    required this.strokeWidth,
  });

  final Color color;
  final double hookWidth;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final top = strokeWidth;
    final bottom = size.height - strokeWidth;
    final midY = size.height * 0.62;

    final path = Path()
      ..moveTo(0, midY)
      ..lineTo(hookWidth * 0.32, midY - strokeWidth)
      ..lineTo(hookWidth * 0.62, bottom)
      ..lineTo(hookWidth, top)
      ..lineTo(size.width - strokeWidth, top);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RadicalPainter old) =>
      old.color != color ||
      old.hookWidth != hookWidth ||
      old.strokeWidth != strokeWidth;
}

class _CursorBar extends StatefulWidget {
  const _CursorBar({required this.height});
  final double height;

  @override
  State<_CursorBar> createState() => _CursorBarState();
}

class _CursorBarState extends State<_CursorBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 2,
        height: widget.height,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        color: YggGlassTokens.confirmActionColor,
      ),
    );
  }
}
