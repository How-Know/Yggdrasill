import 'geom.dart';
import 'scene.dart';

/// 계산된 그림을 인쇄용 TikZ 로 적는다.
///
/// 좌표는 엔진이 이미 다 계산했으므로 TikZ 는 받은 좌표대로 긋기만 한다. 글자만 XeLaTeX 이
/// 본문과 같은 글꼴로 조판한다. 그림의 크기는 엔진이 정한 그림판 크기로 고정된다.
String sceneToTikz(Scene scene) {
  final b = StringBuffer();
  b.writeln('% ygg-figure engine=${scene.engine} style=${scene.style}');
  b.writeln(r'\begin{tikzpicture}[x=1mm,y=-1mm,line join=round]');
  b.writeln('\\useasboundingbox (0,0) rectangle (${_f(scene.width)},${_f(scene.height)});');
  for (final item in scene.items) {
    switch (item) {
      case PathItem():
        final opts = <String>[];
        final fill = item.fill;
        if (fill != null) {
          opts.add(fill <= 0 ? 'fill=black' : (fill >= 1 ? 'fill=white' : 'fill=black!${_f((1 - fill) * 100)}'));
        }
        final stroke = item.stroke;
        if (stroke != null) {
          opts.add('draw');
          opts.add('line width=${_f(stroke.width)}mm');
          opts.add(stroke.roundCap ? 'line cap=round' : 'line cap=butt');
          final dash = stroke.dash;
          if (dash != null) opts.add('dash pattern=on ${_f(dash[0])}mm off ${_f(dash[1])}mm');
        }
        b.writeln('\\path[${opts.join(',')}] ${_path(item.path)};');
      case TextItem():
        final opts = <String>[
          'outer sep=0pt',
          item.background ? 'inner sep=0.5mm,fill=white' : 'inner sep=0pt',
          item.anchorDeg == null ? 'anchor=center' : 'anchor=${_f(item.anchorDeg!)}',
        ];
        final size = '\\fontsize{${_f(item.sizePt)}pt}{${_f(item.sizePt * 1.2)}pt}\\selectfont ';
        final body = item.raw ? item.tex : '\$${item.tex}\$';
        b.writeln('\\node[${opts.join(',')}] at (${_f(item.pos.x)},${_f(item.pos.y)}) {$size$body};');
    }
  }
  b.writeln(r'\end{tikzpicture}%');
  return b.toString();
}

/// 그림 한 장만 든 문서(그림판 크기 = 종이 크기). 겹쳐 비교와 미리보기에 쓴다.
/// 수식 글꼴은 v2 인쇄 문서와 같다(Latin Modern Math).
String standaloneDocument(Scene scene) {
  final tikz = sceneToTikz(scene);
  final hangul = RegExp(r'[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7A3]').hasMatch(tikz);
  return [
    r'\documentclass{article}',
    '\\usepackage[paperwidth=${_f(scene.width)}mm,paperheight=${_f(scene.height)}mm,margin=0mm]{geometry}',
    r'\usepackage{fontspec}',
    r'\usepackage{amsmath,amssymb}',
    r'\usepackage{unicode-math}',
    r'\setmathfont{Latin Modern Math}',
    if (hangul) r'\usepackage{kotex}',
    r'\usepackage{tikz}',
    r'\pagestyle{empty}',
    r'\setlength{\parindent}{0pt}',
    r'\begin{document}%',
    r'\vbox to \paperheight{\offinterlineskip\hbox to \paperwidth{%',
    tikz,
    r'\hss}\vss}%',
    r'\end{document}',
    '',
  ].join('\n');
}

String _path(Path2 path) {
  final b = StringBuffer();
  var i = 0;
  for (final c in path.cmds) {
    switch (c) {
      case Cmd.move:
        if (b.isNotEmpty) b.write(' ');
        b.write(_pt(path.pts[i]));
        i += 1;
      case Cmd.line:
        b.write(' -- ${_pt(path.pts[i])}');
        i += 1;
      case Cmd.cubic:
        b.write(' .. controls ${_pt(path.pts[i])} and ${_pt(path.pts[i + 1])} .. ${_pt(path.pts[i + 2])}');
        i += 3;
      case Cmd.close:
        b.write(' -- cycle');
    }
  }
  return b.toString();
}

String _pt(P p) => '(${_f(p.x)},${_f(p.y)})';

/// 소수 셋째 자리(0.001mm)까지. 같은 그림은 언제나 같은 글자열이 되게 한다.
String _f(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s == '-0' ? '0' : s;
}
