import 'dart:convert';

import 'package:ygg_figure/ygg_figure.dart';

/// 그림 편집 Preview 목업 데이터. 서버·저장소를 읽지 않는다.
/// 그림 파일은 그림 엔진(packages/ygg_figure)의 수능 대표 그림 두 장을 그대로 옮긴 것이다.

/// 끌어 움직일 수 있는 변수(점의 자리 등).
class FigureMockHandle {
  const FigureMockHandle(this.param, this.label, this.min, this.max);
  final String param;
  final String label;
  final double min;
  final double max;
}

class FigureMock {
  const FigureMock({required this.title, required this.source, required this.stem, required this.handles});
  final String title;
  final String source;
  final String stem;
  final List<FigureMockHandle> handles;

  Map<String, dynamic> newDoc() => jsonDecode(source) as Map<String, dynamic>;
}

const figureMocks = [
  FigureMock(
    title: '2022 미적분 28번',
    stem: '그림과 같이 중심이 O이고 길이가 2인 선분 AB를 지름으로 하는 반원 위에 ∠AOC = π/2인 점 C가 있다. '
        '호 BC 위에 점 P와 호 CA 위에 점 Q를 PB = QC가 되도록 잡고, 선분 AP 위에 점 R를 ∠CQR = π/2가 되도록 잡는다. '
        '선분 AP와 선분 CO의 교점을 S라 하자.',
    handles: [
      FigureMockHandle('th', '점 P의 자리', 9, 30),
      FigureMockHandle('qa', '점 Q의 자리', 105, 150),
    ],
    source: r'''
{
  "format": "ygg-figure/1",
  "style": "csat-2026.2",
  "params": {"u": 45.9415, "ox": 48.8352, "oy": 50.5089, "th": 17.4297, "qa": 124.586},
  "canvas": {"width": 98.0, "height": 59.52, "origin": ["ox", "oy"], "unit": "u"},
  "objects": [
    {"id": "O", "type": "point", "at": [0, 0], "label": {"dir": "S", "dist": 1.0}},
    {"id": "A", "type": "point", "at": [-1, 0], "label": {"dir": "SW", "dist": 0.6}},
    {"id": "B", "type": "point", "at": [1, 0], "label": {"dir": "SE", "dist": 0.6}},
    {"id": "C", "type": "point", "at": [0, 1], "label": {"dir": "N", "dist": 0.8}},
    {"id": "k", "type": "arc", "center": "O", "radius": 1, "angles": [0, 180]},
    {"id": "P", "type": "on", "of": "k", "angle": "2th", "label": {"dir": "NE", "dist": 0.6}},
    {"id": "Q", "type": "on", "of": "k", "angle": "qa", "label": {"dir": "NW", "dist": 0.6}},
    {"id": "qr", "type": "perpendicular", "through": "Q", "to": ["Q", "C"], "draw": false},
    {"id": "R", "type": "intersect", "of": ["qr", ["A", "P"]], "label": {"dir": "W", "dist": 1.4}},
    {"id": "S", "type": "intersect", "of": [["A", "P"], ["O", "C"]], "label": {"dir": "NE", "dist": 1.2}},
    {"type": "fill", "path": ["C", "Q", "R", "S"], "shade": 0.895},
    {"type": "fill", "path": ["O", "P", "B"], "shade": 0.895},
    {"type": "segment", "from": "A", "to": "B"},
    {"type": "segment", "from": "O", "to": "C"},
    {"type": "segment", "from": "A", "to": "P"},
    {"type": "segment", "from": "O", "to": "P"},
    {"type": "segment", "from": "P", "to": "B"},
    {"type": "segment", "from": "C", "to": "Q"},
    {"type": "segment", "from": "Q", "to": "R"},
    {"type": "right_angle", "at": "O", "from": "A", "to": "C", "size": 2.3},
    {"type": "right_angle", "at": "Q", "from": "C", "to": "R", "size": 2.3},
    {"id": "ath", "type": "angle", "at": "A", "from": "B", "to": "P", "radius": 7.5, "label": {"text": "\\theta", "dist": 11.5}},
    {"id": "dim", "type": "dimension", "from": "A", "to": "B", "bulge": -7.2, "label": "2"},
    {"id": "lg", "type": "label", "at": [-0.236, 0.586], "text": "g(\\theta)"},
    {"id": "lf", "type": "label", "at": [0.649, 0.214], "text": "f(\\theta)"}
  ],
  "label_nudge": {"O": [0.085, 0.085], "A": [0.339, 0.085], "B": [0.339, 0.0], "C": [-0.085, 0.339], "P": [0.254, -0.254], "Q": [0.508, 0.339], "R": [0.169, 1.695], "S": [0.254, 1.356], "ath": [0.169, 0.169], "dim": [0.085, 0.424], "lg": [0.424, -0.593], "lf": [-0.678, -0.424]}
}
''',
  ),
  FigureMock(
    title: '2023 공통 13번',
    stem: '그림과 같이 AB = 3, BC = √13, AD × CD = 9, ∠BAC = π/3인 사각형 ABCD가 있다. '
        '삼각형 ABC의 넓이를 S₁, 삼각형 ACD의 넓이를 S₂라 하고, 삼각형 ACD의 외접원의 반지름의 길이를 R라 하자.',
    handles: [
      FigureMockHandle('da', '점 D의 자리', 40, 120),
      FigureMockHandle('aa', '점 A의 자리', 135, 170),
    ],
    source: r'''
{
  "format": "ygg-figure/1",
  "style": "csat-2026.2",
  "params": {"ox": 30.416, "oy": 26.2911, "r": 21.4432, "aa": 150.1052, "da": 83.6527, "ca": -61.7391, "bx": -27.0376},
  "canvas": {"width": 52.49, "height": 49.15, "origin": ["ox", "oy"], "unit": 1},
  "objects": [
    {"id": "k", "type": "circle", "center": [0, 0], "radius": "r"},
    {"id": "A", "type": "on", "of": "k", "angle": "aa", "label": {"dir": "NW", "dist": 0.6}},
    {"id": "D", "type": "on", "of": "k", "angle": "da", "label": {"dir": "N", "dist": 1.0}},
    {"id": "C", "type": "on", "of": "k", "angle": "ca", "label": {"dir": "SE", "dist": 0.6}},
    {"id": "B", "type": "point", "at": ["bx", "C.y"], "label": {"dir": "SW", "dist": 0.6}},
    {"type": "polygon", "points": ["A", "B", "C"]},
    {"type": "polyline", "points": ["A", "D", "C"]},
    {"id": "ang", "type": "angle", "at": "A", "from": "B", "to": "C", "radius": 3.2, "label": {"text": "\\dfrac{\\pi}{3}", "dist": 6.8}}
  ],
  "label_nudge": {"A": [0.085, 0.0], "D": [-0.085, 0.0], "C": [0.085, 0.254], "B": [0.17, 0.509], "ang": [-0.424, -0.339]}
}
''',
  ),
];

/// 양식 × 자리마다 그림 크기 하나(목업 값. 실제 값은 사장님이 정한다).
final figureMockSizeTable = FigureSizeTable.fromJson(const {
  'format': 'ygg-figure-sizes/1',
  'slots': [
    {'format': 'mock', 'position': 'below-stem', 'width_em': 17.5, 'max_height_em': 17.5},
    {'format': 'mock', 'position': 'below-choices', 'width_em': 17.5, 'max_height_em': 17.5},
    {'format': 'mock', 'position': 'inline-right', 'width_em': 11.0, 'max_height_em': 13.0},
    {'format': 'naesin', 'position': 'below-stem', 'width_em': 16.0, 'max_height_em': 16.0},
    {'format': 'naesin', 'position': 'below-choices', 'width_em': 16.0, 'max_height_em': 16.0},
    {'format': 'naesin', 'position': 'inline-right', 'width_em': 10.0, 'max_height_em': 12.0},
    {'format': 'assignment', 'position': 'below-stem', 'width_em': 13.0, 'max_height_em': 13.0},
    {'format': 'assignment', 'position': 'below-choices', 'width_em': 13.0, 'max_height_em': 13.0},
    {'format': 'assignment', 'position': 'inline-right', 'width_em': 8.5, 'max_height_em': 10.0},
  ],
});

const figureMockFormatLabels = {'assignment': '과제', 'naesin': '내신 (B4)', 'mock': '모의고사 (8절)'};
const figureMockPositionLabels = {'below-stem': '본문 아래', 'below-choices': '선지 아래', 'inline-right': '본문 오른쪽'};

/// 양식별 한 단의 너비(본문 글자 수 기준, 목업 값).
const figureMockColumnEm = {'assignment': 22.0, 'naesin': 27.0, 'mock': 29.5};
