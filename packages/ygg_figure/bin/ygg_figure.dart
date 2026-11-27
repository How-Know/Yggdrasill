// 그림 엔진 명령줄 도구.
//
//   dart run ygg_figure render  <그림.json> [--ppi 600] [--out <폴더>]
//   dart run ygg_figure compare <그림.json> [--ref <원본 id>] [--out <폴더>]
//   dart run ygg_figure fit     <그림.json> [--params a,b,c] [--ref <원본 id>] [--evals 400] [--write]
//   dart run ygg_figure snap    <그림.json> [--ref <원본 id>] [--write]
//   dart run ygg_figure match   <그림.json> [--ref <원본 id>]
//   dart run ygg_figure export  <그림.json | 폴더> [--out <폴더>] [--ppi 600]
//                               [--sizes <크기 표.json>] [--formats mock,naesin] [--positions below-stem] [--jobs 4]
//
// render : 그림을 PDF·PNG 로 낸다.
// compare: 원본(reference/images/<id>.png)과 겹쳐 보고 점수를 낸다. --ref 가 없으면 파일의 "ref" 를 쓴다.
// fit    : 변수들을 원본에 가장 잘 겹치는 값으로 맞춘다. 변수는 --params 나 파일의 "fit" 에 적는다.
// snap   : 글자(라벨)를 원본의 글자 자리로 옮긴다. 옮긴 양은 파일의 "label_nudge" 에 적는다.
//          파일의 "snap_skip" 에 적힌 라벨은 옮기지 않는다(선과 겹치지 않게 일부러 원본과 달리 둔 글자).
// match  : fit → snap → compare 를 차례로 하고 파일에 적는다.
// export : 문항에 붙일 묶음을 낸다. <out>/<그림 이름>/ 에 figure.pdf(인쇄용 벡터), figure.png(화면용),
//          figure.json(그림 파일), asset.json(크기와 버전)을 적는다. 폴더를 주면 그 안의 그림을 모두 낸다.
//          --sizes 로 크기 표를 주면 양식 × 자리마다 그 크기로 다시 그린 그림(도형만 커지고 글자는 그대로)도
//          figure@<양식>.<자리>.pdf 로 내고 asset.json 의 "variants" 에 적는다. --jobs 는 한꺼번에 그릴 그림 수다.
//          가장 작게 실리는 과제형 크기(오른쪽 어울림은 빼고)에서는 글자가 선과 겹치는지도 살펴
//          겹친 글자를 "label_overlaps" 에 적는다.
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:ygg_figure/src/compare.dart';
import 'package:ygg_figure/src/io/overlap.dart';
import 'package:ygg_figure/src/io/print.dart';
import 'package:ygg_figure/src/io/sized.dart';
import 'package:ygg_figure/src/raster/gray_map.dart';
import 'package:ygg_figure/ygg_figure.dart';

typedef _Ref = ({String id, GrayMap map, double ppi, double widthMm, double heightMm});

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('사용법: dart run ygg_figure <render|compare|fit|snap|match> <그림.json> [옵션]');
    exit(64);
  }
  final command = args[0];
  if (command == 'export') {
    await _exportAll(args);
    return;
  }
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

/// TeX 1pt 의 길이(mm).
const _mmPerPt = mmPerPt;

Future<void> _exportAll(List<String> args) async {
  final target = args[1];
  final files = FileSystemEntity.isDirectorySync(target)
      ? (Directory(target).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : [File(target)];
  final outRoot = Directory(_arg(args, '--out') ?? p.join(Directory.current.path, 'build', 'export'));
  final ppi = double.parse(_arg(args, '--ppi') ?? '600');
  final sizesPath = _arg(args, '--sizes');
  final sizes = sizesPath == null
      ? null
      : FigureSizeTable.fromJson(jsonDecode(File(sizesPath).readAsStringSync()) as Map<String, dynamic>);
  final formats = _arg(args, '--formats')?.split(',') ?? figureFormats;
  final positions = _arg(args, '--positions')?.split(',') ?? figurePositions;
  // 그림마다 조판을 여러 번 하므로, --jobs 만큼 여러 장을 한꺼번에 낸다(그림마다 작업 폴더가 따로다).
  final jobs = int.parse(_arg(args, '--jobs') ?? '1').clamp(1, 16);
  var failed = 0;
  final queue = [...files];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final file = queue.removeAt(0);
      final name = p.basenameWithoutExtension(file.path);
      try {
        final asset = await exportFigure(file, Directory(p.join(outRoot.path, name)),
            ppi: ppi, sizes: sizes, formats: formats, positions: positions);
        final lines = StringBuffer(
            '$name  ${asset['width_mm']}x${asset['height_mm']}mm  ${asset['width_em']}x${asset['height_em']}em');
        for (final v in (asset['variants'] as List? ?? const [])) {
          lines.write('\n    ${v['format']}/${v['position']}  ${v['width_em']}x${v['height_em']}em  도형 배율 ${v['scale']}'
              '${v['source'] == 'figure' ? '  (따로 정함)' : ''}${v['needs_check'] == true ? '  확인 필요' : ''}'
              '${v['label_overlaps'] == null ? '' : '  글자 겹침: ${(v['label_overlaps'] as List).join(', ')}'}');
        }
        stdout.writeln(lines);
      } on FigureError catch (e) {
        failed += 1;
        stderr.writeln('$name: $e');
      } on StateError catch (e) {
        failed += 1;
        stderr.writeln('$name: ${e.message}');
      }
    }
  }

  await Future.wait([for (var i = 0; i < jobs; i++) worker()]);
  stdout.writeln('${files.length - failed}장 → ${outRoot.path}');
  if (failed > 0) exit(1);
}

/// 그림 한 장을 문항에 붙일 묶음으로 낸다. 적은 asset.json 내용을 돌려준다.
///
/// 그림은 그림체가 정한 본문 글자 크기(body_pt)에 맞춰 그려져 있다. 인쇄할 때는 그 비율을 지키도록
/// 크기를 본문 글자 기준(em)으로도 적어 둔다.
///
/// [sizes] 가 있으면 [formats] × [positions] 의 칸마다 그 크기로 다시 그린 그림도 낸다.
Future<Map<String, dynamic>> exportFigure(
  File file,
  Directory outDir, {
  double ppi = 600,
  FigureSizeTable? sizes,
  List<String> formats = figureFormats,
  List<String> positions = figurePositions,
}) async {
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final scene = buildFigure(doc);
  final style = FigureStyle.byName(scene.style);
  final pdf = await renderPdf(scene, outDir, 'figure');
  final png = await rasterize(pdf, ppi);
  final tex = File(p.join(outDir.path, 'figure.tex'));
  if (tex.existsSync()) tex.deleteSync();
  // 그리는 글(TikZ)도 함께 낸다. 인쇄 문서가 이것을 직접 조판하면 그림 속 글자가 그 문서의 본문 글꼴로 찍힌다.
  File(p.join(outDir.path, 'figure.tikz')).writeAsStringSync(sceneToTikz(scene));
  File(p.join(outDir.path, 'figure.json')).writeAsStringSync(formatFigure(doc));
  final shot = GrayMap.readPng(png.path);
  final emMm = style.bodyPt * _mmPerPt;
  final asset = <String, dynamic>{
    'format': 'ygg-figure-asset/1',
    'id': p.basenameWithoutExtension(file.path),
    'ref': doc['ref'],
    // 그림에 붙인 이름표: 큰 종류, 구도·곡선 종류 태그, 그림 파일에서 뽑은 요소 태그, 크기 부류(소·중·대).
    if (doc['kind'] != null) 'kind': doc['kind'],
    if (doc['tags'] is List && (doc['tags'] as List).isNotEmpty) 'tags': doc['tags'],
    'elements': figureElements(doc),
    if ((doc['size'] as Map?)?['variant'] != null) 'size_class': (doc['size'] as Map)['variant'],
    'engine': scene.engine,
    'style': scene.style,
    'body_pt': style.bodyPt,
    'width_mm': _r3(scene.width),
    'height_mm': _r3(scene.height),
    'width_em': _r3(scene.width / emMm),
    'height_em': _r3(scene.height / emMm),
    'png_ppi': ppi,
    'width_px': shot.width,
    'height_px': shot.height,
    'files': {'pdf': 'figure.pdf', 'png': 'figure.png', 'source': 'figure.json', 'tikz': 'figure.tikz'},
  };
  if (sizes != null) {
    // 크기가 같은 칸(예: 본문 아래와 선지 아래)은 한 번만 그리고 같은 파일을 가리키게 한다.
    final drawn = <String, Map<String, dynamic>>{};
    final variants = <Map<String, dynamic>>[];
    for (final format in formats) {
      for (final position in positions) {
        final slot = sizes.slotFor(doc, format, position);
        if (slot == null) continue;
        final boxKey = '${slot.widthEm}x${slot.maxHeightEm}';
        var made = drawn[boxKey];
        if (made == null) {
          final sized = await fitToBox(
            doc,
            widthMm: slot.widthEm * emMm,
            maxHeightMm: slot.maxHeightEm == null ? null : slot.maxHeightEm! * emMm,
            work: Directory(p.join(outDir.path, 'work')),
          );
          final fileName = 'figure@$format.$position';
          await renderPdf(sized.scene, outDir, fileName);
          final variantTex = File(p.join(outDir.path, '$fileName.tex'));
          if (variantTex.existsSync()) variantTex.deleteSync();
          File(p.join(outDir.path, '$fileName.tikz')).writeAsStringSync(sceneToTikz(sized.scene));
          // 도형이 가장 작아지는 과제형에서 글자가 선과 안 겹치면 더 큰 양식에서도 안 겹친다.
          // 오른쪽 어울림은 원본부터 작게 그린 그림에만 쓰는 자리라 살피지 않는다.
          final overlaps = format == 'assignment' && position != 'inline-right'
              ? await findLabelOverlaps(sized.scene, Directory(p.join(outDir.path, 'work')))
              : const <LabelOverlap>[];
          made = drawn[boxKey] = {
            'scale': _r3(sized.scale),
            'width_mm': _r3(sized.scene.width),
            'height_mm': _r3(sized.scene.height),
            'width_em': _r3(sized.scene.width / emMm),
            'height_em': _r3(sized.scene.height / emMm),
            'pdf': '$fileName.pdf',
            'tikz': '$fileName.tikz',
            // 도형을 많이 줄이면 글자끼리 붙을 수 있다. 사람이 한 번 보게 표시해 둔다.
            if (sized.scale < 0.65 || sized.scale > 1.6 || overlaps.isNotEmpty) 'needs_check': true,
            if (overlaps.isNotEmpty) 'label_overlaps': [for (final o in overlaps) o.key],
          };
        }
        variants.add({
          'format': format,
          'position': position,
          if (slot.variant != null) 'variant': slot.variant,
          'source': slot.fromFigure ? 'figure' : 'table',
          if (slot.note != null) 'note': slot.note,
          ...made,
        });
      }
    }
    final work = Directory(p.join(outDir.path, 'work'));
    if (work.existsSync()) work.deleteSync(recursive: true);
    asset['variants'] = variants;
  }
  File(p.join(outDir.path, 'asset.json')).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(asset)}\n');
  return asset;
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
  // 글자가 선에 닿지 않게 일부러 원본과 다른 자리에 둔 라벨은 파일의 "snap_skip" 에 적어 두고 옮기지 않는다.
  final keep = {...?(doc['snap_skip'] as List?)?.cast<String>()};
  moves.forEach((key, m) {
    if (keep.contains(key)) return;
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
