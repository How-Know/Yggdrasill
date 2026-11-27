import 'package:test/test.dart';
import 'package:ygg_figure/src/io/overlap.dart';
import 'package:ygg_figure/src/raster/gray_map.dart';
import 'package:ygg_figure/ygg_figure.dart';

/// 흰 종이(254.0ppi = 1mm 에 10점)에 검은 네모들을 찍는다. 네모는 [왼쪽, 위, 너비, 높이](mm).
GrayMap _paper(List<List<double>> boxes) {
  final map = GrayMap(400, 200)..data.fillRange(0, 400 * 200, 255);
  for (final b in boxes) {
    for (var y = (b[1] * 10).round(); y < ((b[1] + b[3]) * 10).round(); y++) {
      for (var x = (b[0] * 10).round(); x < ((b[0] + b[2]) * 10).round(); x++) {
        map.data[y * 400 + x] = 0;
      }
    }
  }
  return map;
}

void main() {
  const ppi = 254.0;
  final texts = [
    TextItem(const P(10, 10), 'A', sizePt: 10.5, key: 'A'),
    TextItem(const P(30, 10), 'y=f(x)', sizePt: 10.5, key: 'lf'),
  ];
  // 글자 A 는 한 덩어리, 함수명은 0.4mm 틈을 둔 낱자 셋.
  final letters = _paper([
    [9, 9, 2, 2],
    [26, 9, 2, 2],
    [28.4, 9, 2, 2],
    [30.8, 9, 2, 2],
  ]);

  test('선이 지나간 글자만 겹침으로 낸다', () {
    // 세로선이 함수명의 첫 낱자를 지난다.
    final shapes = _paper([
      [26.5, 0, 0.4, 20],
    ]);
    final found = labelOverlaps(shapes, letters, texts, ppi);
    expect(found.map((o) => o.key), ['lf']);
    expect(found.single.areaMm2, closeTo(0.8, 0.05));
  });

  test('선이 글자에서 떨어져 있거나 스치기만 하면 겹침이 아니다', () {
    expect(labelOverlaps(_paper([[20, 0, 0.4, 20]]), letters, texts, ppi), isEmpty);
    // 0.1mm × 0.2mm 만 닿았다.
    expect(labelOverlaps(_paper([[8.8, 8.9, 0.3, 0.3]]), letters, texts, ppi), isEmpty);
  });

  test('겹친 넓이가 큰 글자부터 낸다', () {
    final shapes = _paper([
      [9.5, 0, 0.3, 20],
      [26, 9.5, 8, 0.4],
    ]);
    expect(labelOverlaps(shapes, letters, texts, ppi).map((o) => o.key), ['lf', 'A']);
  });
}
