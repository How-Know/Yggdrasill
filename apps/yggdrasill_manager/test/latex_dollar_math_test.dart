import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/widgets/latex_text_renderer.dart';

void main() {
  String norm(String s) => LatexTextRenderer.inlineDollarMath(s);

  test('문장 속 \$…\$는 \\(…\\)로 바뀐다', () {
    expect(norm(r'넓이는 $\frac{1}{2}ab$ 이다'), r'넓이는 \(\frac{1}{2}ab\) 이다');
    expect(norm(r'$a$와 $b$'), r'\(a\)와 \(b\)');
  });

  test('\$\$…\$\$와 \\(…\\)는 그대로 둔다', () {
    expect(norm('앞\n\$\$x^2+1\$\$\n뒤 \$y\$'), '앞\n\$\$x^2+1\$\$\n뒤 \\(y\\)');
    expect(norm(r'\(a$b\) 와 $c$'), r'\(a$b\) 와 \(c\)');
  });

  test('닫히지 않은 \$는 글자로 남긴다', () {
    expect(norm(r'값은 $5'), r'값은 $5');
    expect(norm('수식 없음'), '수식 없음');
  });
}
