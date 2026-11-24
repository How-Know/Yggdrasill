// 그림 엔진 명령줄 도구.
//
//   dart run ygg_figure render  <그림.json> [--ppi 600] [--out <폴더>]
//   dart run ygg_figure compare <그림.json> [--ref <원본 id>] [--out <폴더>]
//   dart run ygg_figure fit     <그림.json> [--params a,b,c] [--ref <원본 id>] [--evals 400] [--write]
//   dart run ygg_figure snap    <그림.json> [--ref <원본 id>] [--write]
//   dart run ygg_figure match   <그림.json> [--ref <원본 id>]
//
// render : 그림을 PDF·PNG 로 낸다.
// compare: 원본(reference/images/<id>.png)과 겹쳐 보고 점수를 낸다. --ref 가 없으면 파일의 "ref" 를 쓴다.
// fit    : 변수들을 원본에 가장 잘 겹치는 값으로 맞춘다. 변수는 --params 나 파일의 "fit" 에 적는다.
// snap   : 글자(라벨)를 원본의 글자 자리로 옮긴다. 옮긴 양은 파일의 "label_nudge" 에 적는다.
// match  : fit → snap → compare 를 차례로 하고 파일에 적는다.
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:ygg_figure/src/compare.dart';
import 'package:ygg_figure/src/io/print.dart';
import 'package:ygg_figure/src/raster/gray_map.dart';
import 'package:ygg_figure/ygg_figure.dart';

typedef _Ref = ({String id, GrayMap map, double ppi, double widthMm, double heightMm});

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('사용법: dart run ygg_figure <render|compare|fit|snap|match> <그림.json> [옵션]');
    exit(64);
  }
  final command = args[0];
  final file = File(args[1]);
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final name = p.basenameWithoutExtension(file.path);
  final outDir = Directory(_arg(args, '--out') ?? p.join(Directory.current.path, 'build', 'figures'));
  final write = args.contains('--write') || command == 'match';
  _Ref ref() => _reference(_arg(args, '--ref') ?? doc['ref'] as String?);
  try {
    switch (command) {
      case 'render':
        final scene = buildFigure(doc);
        final pdf = await renderPdf(scene, outDir, name);
        final png = await rasterize(pdf, double.parse(_arg(args, '--ppi') ?? '600'));
        stdout.writeln('${scene.width}x${scene.height}mm → ${png.path}');
      case 'compare':
        stdout.writeln(jsonEncode(await _compare(doc, ref(), outDir, name)));
      case 'fit':
        final result = _fit(doc, ref(), args);
        stdout.writeln(jsonEncode(result));
        if (write) file.writeAsStringSync(formatFigure(doc));
      case 'snap':
        stdout.writeln(jsonEncode(await _snap(doc, ref(), outDir, name)));
        if (write) file.writeAsStringSync(formatFigure(doc));
      case 'match':
        final r = ref();
        if ((doc['fit'] as List? ?? const []).isNotEmpty || _arg(args, '--params') != null) {
          stdout.writeln(jsonEncode(_fit(doc, r, args)));
        }
        stdout.writeln(jsonEncode(await _snap(doc, r, outDir, name)));
        file.writeAsStringSync(formatFigure(doc));
        stdout.writeln(jsonEncode(await _compare(doc, r, outDir, name)));
      default:
        stderr.writeln('모르는 명령입니다: $command');
        exit(64);
    }
  } on FigureError catch (e) {
    stderr.writeln(e);
    exit(1);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}

Future<Map<String, dynamic>> _compare(Map<String, dynamic> doc, _Ref ref, Directory outDir, String name) async {
  final scene = referenceView(doc, buildFigure(doc), widthMm: ref.widthMm, heightMm: ref.heightMm);
  final ours = await renderGray(scene, outDir, name, ref.ppi);
  final result = compareMaps(ref.map, ours, ppi: ref.ppi);
  final overlayPath = p.join(outDir.path, '$name-overlay.png');
  File(overlayPath).writeAsBytesSync(img.encodePng(result.overlay));
  return {
    'ref': ref.id,
    'size_mm': [scene.width, scene.height],
    'covered': _r3(result.covered),
    'precise': _r3(result.precise),
    'covered_loose': _r3(result.coveredLoose),
    'precise_loose': _r3(result.preciseLoose),
    'mean_miss_mm': _r3(result.meanMissMm),
    'fill_match': result.fillMatch == null ? null : _r3(result.fillMatch!),
    'ink_ratio': _r3(result.inkRatio),
    'overlay': overlayPath,
  };
}

/// 변수를 원본에 맞춘다. 나아졌으면 [doc] 의 params 를 고친다.
Map<String, dynamic> _fit(Map<String, dynamic> doc, _Ref ref, List<String> args) {
  final names = _arg(args, '--params')?.split(',').where((s) => s.isNotEmpty).toList() ??
      (doc['fit'] as List? ?? const []).cast<String>();
  if (names.isEmpty) throw FigureError('맞출 변수가 없습니다. --params 나 파일의 "fit" 에 적어 주세요');
  final current = figureParams(doc);
  for (final n in names) {
    if (!current.containsKey(n)) throw FigureError('변수 "$n" 이(가) 그림 파일의 params 에 없습니다');
  }
  final target = FitTarget(ref.map, ref.ppi);
  double cost(List<double> v) {
    try {
      final scene = buildFigure(doc, params: {for (var i = 0; i < names.length; i++) names[i]: v[i]});
      return target.cost(referenceView(doc, scene, widthMm: ref.widthMm, heightMm: ref.heightMm));
    } on FigureError {
      return 1e9; // 관계가 성립하지 않는 값(교점이 없어지는 등)은 버린다.
    }
  }

  final start = [for (final n in names) current[n]!];
  final stepScale = double.parse(_arg(args, '--step') ?? '1');
  final steps = [for (final v in start) stepScale * (v.abs() * 0.02 > 0.3 ? v.abs() * 0.02 : 0.3)];
  final evals = int.parse(_arg(args, '--evals') ?? '${200 + 120 * names.length}');
  final before = cost(start);
  var best = minimize(cost, start, steps, maxEvals: evals);
  // 좁은 걸음으로 두 번 더 시작한다. 얕은 골짜기에 걸린 값을 조금 더 밀어 준다.
  best = minimize(cost, best, [for (final s in steps) s / 4], maxEvals: evals ~/ 2);
  best = minimize(cost, best, [for (final s in steps) s / 16], maxEvals: evals ~/ 2);
  final after = cost(best);
  final fitted = {for (var i = 0; i < names.length; i++) names[i]: _r4(best[i])};
  if (after < before) {
    final params = doc['params'] as Map<String, dynamic>;
    fitted.forEach((k, v) {
      final old = params[k];
      if (old is Map) {
        old['value'] = v;
      } else {
        params[k] = v;
      }
    });
  }
  return {'cost_before': _r4(before), 'cost_after': _r4(after), 'params': fitted};
}

/// 글자를 원본 자리로 옮기고 [doc] 의 label_nudge 를 고친다.
Future<Map<String, dynamic>> _snap(Map<String, dynamic> doc, _Ref ref, Directory outDir, String name) async {
  final scene = referenceView(doc, buildFigure(doc), widthMm: ref.widthMm, heightMm: ref.heightMm);
  final textOnly = Scene(
    width: scene.width,
    height: scene.height,
    items: scene.items.whereType<TextItem>().toList(),
    style: scene.style,
    engine: scene.engine,
  );
  if (textOnly.items.isEmpty) return {'labels': 0};
  final labels = await renderGray(textOnly, outDir, '$name-labels', ref.ppi);
  final moves = snapLabels(original: ref.map, labelsOnly: labels, scene: scene, ppi: ref.ppi);
  final nudges = <String, dynamic>{...?(doc['label_nudge'] as Map?)?.cast<String, dynamic>()};
  final loose = <String>[];
  moves.forEach((key, m) {
    if (m.miss > 0.22) loose.add(key);
    if (m.dx == 0 && m.dy == 0) return;
    final old = (nudges[key] as List?)?.cast<num>() ?? const [0, 0];
    nudges[key] = [_r3(old[0] + m.dx), _r3(old[1] + m.dy)];
  });
  if (nudges.isNotEmpty) doc['label_nudge'] = nudges;
  return {
    'labels': moves.length,
    'moved': moves.values.where((m) => m.dx != 0 || m.dy != 0).length,
    'not_matched': loose,
  };
}

/// 그림 파일을 사람이 읽기 좋게 적는다(요소 하나에 한 줄).
String formatFigure(Map<String, dynamic> doc) {
  final b = StringBuffer('{\n');
  final keys = doc.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    final k = keys[i], v = doc[k];
    b.write('  ${jsonEncode(k)}: ');
    if (k == 'objects' && v is List) {
      b.write('[\n');
      for (var j = 0; j < v.length; j++) {
        b.write('    ${_inline(v[j])}${j + 1 < v.length ? ',' : ''}\n');
      }
      b.write('  ]');
    } else if (k == 'parts' && v is Map) {
      b.write('{\n');
      final names = v.keys.toList();
      for (var j = 0; j < names.length; j++) {
        final list = v[names[j]] as List;
        b.write('    ${jsonEncode(names[j])}: [\n');
        for (var m = 0; m < list.length; m++) {
          b.write('      ${_inline(list[m])}${m + 1 < list.length ? ',' : ''}\n');
        }
        b.write('    ]${j + 1 < names.length ? ',' : ''}\n');
      }
      b.write('  }');
    } else {
      b.write(_inline(v));
    }
    b.write(i + 1 < keys.length ? ',\n' : '\n');
  }
  b.write('}\n');
  return b.toString();
}

String _inline(dynamic v) {
  if (v is Map) return '{${v.entries.map((e) => '${jsonEncode(e.key)}: ${_inline(e.value)}').join(', ')}}';
  if (v is List) return '[${v.map(_inline).join(', ')}]';
  return jsonEncode(v);
}

_Ref _reference(String? id) {
  if (id == null) throw FigureError('겹쳐 볼 원본을 모릅니다. --ref 나 파일의 "ref" 에 원본 id 를 적어 주세요');
  final root = Directory.current.path;
  final manifest = jsonDecode(File(p.join(root, 'reference', 'manifest.json')).readAsStringSync()) as Map;
  final entry = (manifest['figures'] as List).cast<Map>().firstWhere(
        (f) => f['id'] == id,
        orElse: () => throw FigureError('원본 목록에 없는 id 입니다: $id'),
      );
  return (
    id: id,
    map: GrayMap.readPng(p.join(root, 'reference', 'images', '$id.png')),
    ppi: (entry['ppi'] as num).toDouble(),
    widthMm: (entry['width_mm'] as num).toDouble(),
    heightMm: (entry['height_mm'] as num).toDouble(),
  );
}

double _r3(double v) => (v * 1000).round() / 1000;
double _r4(double v) => (v * 10000).round() / 10000;

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
