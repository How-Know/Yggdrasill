/// 그림 이름표.
///
/// 그림마다 세 겹의 이름표가 붙는다.
///   - 큰 종류("kind"): 그림마다 하나. 그림 파일에 적는다.
///   - 구도·곡선 종류 태그("tags"): 여러 개. 그림 파일에 적는다. 쓸 수 있는 이름은 figures/tags.json 에 있다.
///   - 요소 태그: 그림에 무엇이 그려져 있는지(원, 색칠, 좌표축 …). 그림 파일에서 저절로 뽑는다([figureElements]).
library;

/// 요소 태그의 이름과 적는 순서.
const figureElementNames = <String, String>{
  'triangle': '삼각형',
  'quadrilateral': '사각형',
  'polygon': '다각형',
  'circle': '원',
  'arc': '호',
  'oval': '타원 모양',
  'function-curve': '함수 곡선',
  'parametric-curve': '매개변수 곡선',
  'axes': '좌표축',
  'fill': '색칠 영역',
  'dashed-line': '점선',
  'arrow': '화살표',
  'dot': '점 표시',
  'right-angle': '직각 표시',
  'angle-mark': '각 표시',
  'length-mark': '길이 표시',
  'repeat': '되풀이',
  'space': '공간 좌표',
};

/// 그림 파일에서 요소 태그를 뽑는다.
///
/// 요소의 종류를 보고 정한다(부품 안의 요소도 본다). 선분 여러 개로 그린 삼각형처럼 종류만으로는
/// 알 수 없는 것은 그림 파일의 "elements" 에 손으로 적어 두면 함께 나온다.
List<String> figureElements(Map<String, dynamic> doc) {
  final found = <String>{};
  void see(dynamic object) {
    if (object is! Map) return;
    final type = object['type'];
    // 그리지 않는 요소(교점을 찾으려고 둔 보조 원 등)는 보이지 않으므로 세지 않는다.
    if (object['draw'] == false) return;
    switch (type) {
      case 'circle':
        found.add('circle');
      case 'arc':
        found.add('arc');
      case 'ellipse':
        found.add('oval');
      case 'function':
        found.add('function-curve');
      case 'parametric':
        found.add('parametric-curve');
      case 'polygon':
        found.add('polygon');
        final points = object['points'];
        if (points is List && points.length == 3) found.add('triangle');
        if (points is List && points.length == 4) found.add('quadrilateral');
      case 'fill':
        found.add('fill');
      case 'axes':
        found.add('axes');
      case 'right_angle':
        found.add('right-angle');
      case 'angle':
        found.add('angle-mark');
      case 'dimension':
        found.add('length-mark');
      case 'dot':
        found.add('dot');
      case 'use':
        if (object['count'] != null) found.add('repeat');
    }
    final line = object['line'];
    if (line is String && line.contains('dashed')) found.add('dashed-line');
    if (object['arrow'] != null) found.add('arrow');
    final fill = object['fill'];
    if (fill != null && fill != false && fill != 'white') found.add('fill');
    final dot = object['dot'];
    if (dot != null && dot != false && dot != 'none') found.add('dot');
  }

  for (final object in (doc['objects'] as List? ?? const [])) {
    see(object);
  }
  final parts = doc['parts'];
  if (parts is Map) {
    for (final part in parts.values) {
      final list = part is Map ? part['objects'] : part;
      if (list is List) list.forEach(see);
    }
  }
  if (doc['projection'] is Map) found.add('space');
  final own = doc['elements'];
  if (own is List) found.addAll(own.whereType<String>());
  final order = figureElementNames.keys.toList();
  return found.toList()
    ..sort((a, b) {
      final ia = order.indexOf(a), ib = order.indexOf(b);
      if (ia < 0 || ib < 0) return ia < 0 && ib < 0 ? a.compareTo(b) : (ia < 0 ? 1 : -1);
      return ia.compareTo(ib);
    });
}

/// 그림 파일의 이름표가 태그 목록(figures/tags.json 을 읽은 것)에 맞는지 본다. 문제가 있으면 그 내용을 돌려준다.
List<String> checkFigureTags(Map<String, dynamic> doc, Map<String, dynamic> vocabulary) {
  final problems = <String>[];
  final kinds = (vocabulary['kinds'] as Map?) ?? const {};
  final tags = (vocabulary['tags'] as Map?) ?? const {};
  final kind = doc['kind'];
  if (kind is! String || !kinds.containsKey(kind)) problems.add('큰 종류(kind)가 목록에 없습니다: $kind');
  final own = doc['tags'];
  if (own is! List || own.isEmpty) {
    problems.add('구도 태그(tags)가 없습니다');
  } else {
    for (final tag in own) {
      if (!tags.containsKey(tag)) problems.add('태그 목록에 없는 태그입니다: $tag');
    }
    if (own.toSet().length != own.length) problems.add('같은 태그가 두 번 적혀 있습니다');
  }
  final elements = doc['elements'];
  if (elements is List) {
    for (final e in elements) {
      if (!figureElementNames.containsKey(e)) problems.add('요소 태그 목록에 없는 이름입니다: $e');
    }
  }
  return problems;
}
