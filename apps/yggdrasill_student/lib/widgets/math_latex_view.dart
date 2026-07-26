import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../services/latex_linear.dart';

/// LaTeX 문자열을 2차원 조판 수식으로 그려주는 위젯.
///
/// MyScript 인식 결과나 답지 정답을 학생이 읽기 쉬운 형태로 보여줄 때
/// 쓴다. KaTeX 계열 조판이라 서버 PDF(XeLaTeX) 미리보기와 시각적으로
/// 유사하다. 파싱에 실패하면 원문 텍스트로 폴백한다.
class MathLatexView extends StatelessWidget {
  const MathLatexView({
    super.key,
    required this.latex,
    this.fontSize = 20,
    this.color,
  }) : fallbackText = null;

  /// 앱 선형 표기(`3x^2`, `(2)/(3)`, `√(2)` …)를 LaTeX 로 변환해 그린다.
  MathLatexView.linear(
    String linear, {
    super.key,
    this.fontSize = 20,
    this.color,
  })  : latex = linearToLatex(linear),
        fallbackText = linear;

  final String latex;
  final double fontSize;
  final Color? color;

  /// 파싱 실패 시 보여줄 원문 (선형 표기 원본).
  final String? fallbackText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ??
        (theme.brightness == Brightness.dark ? Colors.white : Colors.black87);
    return Math.tex(
      latex,
      // display 스타일 — 시그마·적분의 위/아래 첨자가 옆이 아니라
      // 위아래로 조판된다.
      mathStyle: MathStyle.display,
      textStyle: TextStyle(fontSize: fontSize, color: effectiveColor),
      onErrorFallback: (_) => Text(
        fallbackText ?? latex,
        style: TextStyle(fontSize: fontSize * 0.8, color: effectiveColor),
      ),
    );
  }
}
