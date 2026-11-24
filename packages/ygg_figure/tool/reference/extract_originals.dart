// 수능 문제지 PDF 에 들어 있는 원본 그림(약 600ppi)을 그대로 꺼내 문항과 잇는다.
//
// 문제은행의 그림 파일은 쪽을 낮은 해상도로 찍어 자른 것이라 선 굵기·글자 크기를 재는
// 기준으로 쓰기 어렵다. 문제지 PDF 는 그림을 600ppi 이미지로 품고 있으므로 그것을 쓴다.
//
// 입력: reference/work/csat_rows.json (tool/reference/csat_figures.sql 의 결과)
// 출력: reference/images/<id>.png, reference/manifest.json
//
//   dart run tool/reference/extract_originals.dart [--pdf-dir <폴더>]
//
// pdftocairo, pdftoppm(TeX Live 또는 poppler)이 PATH 에 있어야 한다.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const _refPxPerPt = 600 / 72;

class _Placed {
  _Placed(this.id, this.image, this.x, this.y, this.w, this.h);
  final String id;
  final img.Image image;
  final double x, y, w, h; // 쪽 위의 자리(pt, 왼쪽 위가 원점)
  double get right => x + w;
  double get bottom => y + h;
  double get area => w * h;
}

class _Rect {
  _Rect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
  double get right => x + w;
  double get bottom => y + h;
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final rowsFile = File(p.join(root, 'reference', 'work', 'csat_rows.json'));
  if (!rowsFile.existsSync()) {
    stderr.writeln('reference/work/csat_rows.json 이 없습니다. csat_figures.sql 을 먼저 돌리세요.');
    exit(2);
  }
  final pdfDir = _argValue(args, '--pdf-dir') ??
      Platform.environment['MOCK_EXAM_DIR'] ??
      p.join(Platform.environment['USERPROFILE'] ?? '', 'Dropbox', '- 모의고사');
  final pdfIndex = <String, String>{};
  for (final e in Directory(pdfDir).listSync(recursive: true)) {
    if (e is File && e.path.toLowerCase().endsWith('.pdf')) {
      pdfIndex[p.basename(e.path)] = e.path;
    }
  }

  final rows = (_readJson(rowsFile)['rows'] as List).cast<Map<String, dynamic>>();
  final imagesDir = Directory(p.join(root, 'reference', 'images'))..createSync(recursive: true);
  final workDir = Directory(p.join(root, 'reference', 'work', 'pages'))..createSync(recursive: true);

  final pageCache = <String, ({List<_Placed> images, double width, double height})>{};
  final itemIdToEntryIds = <String, List<String>>{};
  final entries = <Map<String, dynamic>>[];
  final problems = <String>[];

  for (final row in rows) {
    final year = row['exam_year'] as int;
    final section = '${row['section']}';
    final number = row['problem_number'];
    final fileName = '${row['file_name']}';
    final pdfPath = pdfIndex[fileName];
    final assets = _currentAssets(row['figure_assets']);
    if (pdfPath == null) {
      problems.add('$year $section $number: PDF 없음 ($fileName)');
      continue;
    }
    var order = 0;
    for (final asset in assets) {
      order += 1;
      final id = 'csat-$year-$section-$number-$order';
      // 추출이 자른 그림은 source_page·bbox_1k, 검수에서 원본을 다시 자른 그림은 raw_page·crop_region_1k 를 쓴다.
      final page = ((asset['source_page'] ?? asset['raw_page'] ?? row['raw_page']) as num).toInt();
      final bbox = ((asset['bbox_1k'] ?? asset['crop_region_1k']) as List?)
          ?.map((v) => (v as num).toDouble())
          .toList();
      if (bbox == null || bbox.length != 4) {
        problems.add('$id: 그림 자리(bbox_1k) 없음');
        continue;
      }
      final key = '$pdfPath#$page';
      final pageInfo = pageCache[key] ??= await _readPage(pdfPath, page, workDir);
      // bbox_1k = [ymin, xmin, ymax, xmax], 쪽 크기를 1000 으로 본 값.
      final box = _Rect(
        bbox[1] / 1000 * pageInfo.width,
        bbox[0] / 1000 * pageInfo.height,
        (bbox[3] - bbox[1]) / 1000 * pageInfo.width,
        (bbox[2] - bbox[0]) / 1000 * pageInfo.height,
      );
      final matched = pageInfo.images.where((im) => _overlapShare(im, box) >= 0.5).toList()
        ..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));

      img.Image out;
      _Rect rect;
      String source;
      double pxPerPt;
      if (matched.isNotEmpty) {
        final merged = _compose(matched);
        out = merged.image;
        rect = merged.rect;
        pxPerPt = merged.pxPerPt;
        source = 'pdf_image';
      } else {
        // 그림이 이미지가 아니라 선으로 그려진 쪽이면 600dpi 로 찍어 자른다. 자리는 AI 가 잡은
        // 것이라 원본 이미지만큼 정확하지 않다.
        final rendered = await _renderCrop(pdfPath, page, box, workDir);
        out = rendered;
        rect = box;
        pxPerPt = _refPxPerPt;
        // 가형·나형 공통 문항은 그림 자리가 한쪽 문제지 기준으로만 적혀 있어, 다른 쪽에서는 빈 곳이 찍힌다.
        source = _hasInk(rendered) ? 'page_render' : 'empty';
      }
      final imageFile = File(p.join(imagesDir.path, '$id.png'));
      if (source == 'empty') {
        if (imageFile.existsSync()) imageFile.deleteSync();
      } else {
        imageFile.writeAsBytesSync(img.encodePng(out));
      }
      itemIdToEntryIds.putIfAbsent('${row['item_id']}', () => []).add(id);
      entries.add({
        'id': id,
        'exam_year': year,
        'section': section,
        'problem_number': number,
        'figure_order': order,
        'item_id': row['item_id'],
        'same_as_item_id': row['same_as_item_id'],
        'pb_question_id': row['pb_question_id'],
        'pdf': fileName,
        'page': page,
        'source': source,
        'pieces': matched.length,
        'rect_pt': [_r2(rect.x), _r2(rect.y), _r2(rect.w), _r2(rect.h)],
        'width_mm': _r2(rect.w / 72 * 25.4),
        'height_mm': _r2(rect.h / 72 * 25.4),
        'width_px': out.width,
        'height_px': out.height,
        'ppi': _r2(pxPerPt * 72),
        'layout_position': _layoutPosition(row['figure_layout'], order),
      });
    }
  }

  // 가형·나형에 같은 문항이 있으면 같은 그림이다. 한쪽만 다시 그리면 되도록 짝을 적는다.
  for (final e in entries) {
    final twin = e['same_as_item_id'];
    final twinIds = twin == null ? null : itemIdToEntryIds['$twin'];
    final order = (e['figure_order'] as int) - 1;
    e['same_as'] = (twinIds != null && order < twinIds.length) ? twinIds[order] : null;
    e.remove('same_as_item_id');
  }
  // 짝 가운데 그림이 찍힌 쪽을 기준으로 삼는다.
  final byId = {for (final e in entries) e['id'] as String: e};
  for (final e in entries) {
    final twin = byId[e['same_as']];
    if (twin != null && twin['source'] == 'empty' && e['source'] != 'empty') {
      twin['same_as'] = e['id'];
      e['same_as'] = null;
    }
  }
  for (final e in entries) {
    if (e['source'] == 'empty' && e['same_as'] == null) {
      problems.add('${e['id']}: 그림 자리에 아무것도 없음');
    }
  }

  final manifest = {
    'version': 1,
    'note': '수능 문제지 PDF 에서 꺼낸 원본 그림 목록. 그림 파일은 reference/images 에 있고 저장소에는 넣지 않는다.',
    'figures': entries,
  };
  File(p.join(root, 'reference', 'manifest.json'))
      .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');

  final bySource = <String, int>{};
  for (final e in entries) {
    bySource[e['source'] as String] = (bySource[e['source']] ?? 0) + 1;
  }
  stdout.writeln('그림 ${entries.length}장: $bySource');
  stdout.writeln('짝(같은 그림) ${entries.where((e) => e['same_as'] != null).length}장');
  for (final line in problems) {
    stdout.writeln('확인 필요: $line');
  }
}

String? _argValue(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Map<String, dynamic> _readJson(File file) {
  var text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return jsonDecode(text) as Map<String, dynamic>;
}

/// 그림 번호마다 지금 쓰는 그림 하나만 남긴다(승인된 것 먼저, 그다음 최근 것).
List<Map<String, dynamic>> _currentAssets(dynamic raw) {
  final list = (raw as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  final byIndex = <int, Map<String, dynamic>>{};
  for (var i = 0; i < list.length; i++) {
    final a = list[i];
    final idx = (a['figure_index'] as num?)?.toInt() ?? (i + 1);
    final cur = byIndex[idx];
    if (cur == null || _assetRank(a).compareTo(_assetRank(cur)) > 0) byIndex[idx] = a;
  }
  final keys = byIndex.keys.toList()..sort();
  return [for (final k in keys) byIndex[k]!];
}

String _assetRank(Map<String, dynamic> a) => '${a['approved'] == true ? 1 : 0}|${a['created_at'] ?? ''}';

String? _layoutPosition(dynamic layout, int order) {
  if (layout is! Map) return null;
  final items = layout['items'];
  if (items is! List) return null;
  for (final item in items) {
    if (item is Map && '${item['assetKey']}' == 'idx:$order') return item['position'] as String?;
  }
  return null;
}

double _r2(double v) => (v * 100).round() / 100;

/// 이미지 넓이 가운데 그림 자리 안에 들어온 몫. 자리는 AI 가 잡은 값이라 조금 넓혀서 본다.
double _overlapShare(_Placed im, _Rect box) {
  const pad = 12.0;
  final x0 = math.max(im.x, box.x - pad);
  final y0 = math.max(im.y, box.y - pad);
  final x1 = math.min(im.right, box.right + pad);
  final y1 = math.min(im.bottom, box.bottom + pad);
  if (x1 <= x0 || y1 <= y0 || im.area <= 0) return 0;
  return (x1 - x0) * (y1 - y0) / im.area;
}

/// 한 그림이 여러 조각(위아래 띠)으로 나뉘어 들어 있으면 쪽 위의 자리대로 한 장에 붙인다.
({img.Image image, _Rect rect, double pxPerPt}) _compose(List<_Placed> parts) {
  final x0 = parts.map((e) => e.x).reduce(math.min);
  final y0 = parts.map((e) => e.y).reduce(math.min);
  final x1 = parts.map((e) => e.right).reduce(math.max);
  final y1 = parts.map((e) => e.bottom).reduce(math.max);
  final rect = _Rect(x0, y0, x1 - x0, y1 - y0);
  final pxPerPt = parts.first.image.width / parts.first.w;
  if (parts.length == 1) {
    return (image: _gray(parts.first.image), rect: rect, pxPerPt: pxPerPt);
  }
  final canvas = img.Image(
    width: (rect.w * pxPerPt).round(),
    height: (rect.h * pxPerPt).round(),
    numChannels: 3,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  for (final part in parts) {
    final dstW = (part.w * pxPerPt).round();
    final dstH = (part.h * pxPerPt).round();
    // 같은 해상도의 조각은 다시 그리지 않고(흐려지지 않게) 그대로 붙인다.
    final same = (dstW - part.image.width).abs() <= 1 && (dstH - part.image.height).abs() <= 1;
    final src = same
        ? part.image
        : img.copyResize(part.image, width: dstW, height: dstH, interpolation: img.Interpolation.cubic);
    img.compositeImage(
      canvas,
      src,
      dstX: ((part.x - x0) * pxPerPt).round(),
      dstY: ((part.y - y0) * pxPerPt).round(),
    );
  }
  return (image: _gray(canvas), rect: rect, pxPerPt: pxPerPt);
}

img.Image _gray(img.Image src) {
  // 투명한 곳은 흰 종이로 본다.
  final flat = img.Image(width: src.width, height: src.height, numChannels: 3);
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, src);
  return img.grayscale(flat);
}

final _imageDef = RegExp(r'<image id="([^"]+)" width="(\d+)" height="(\d+)" xlink:href="data:image/(\w+);base64,([^"]+)"');
final _imageUse = RegExp(r'<use xlink:href="#([^"]+)" transform="matrix\(([^)]+)\)"');
final _svgSize = RegExp(r'<svg[^>]*width="([\d.]+)pt" height="([\d.]+)pt"');

Future<({List<_Placed> images, double width, double height})> _readPage(
  String pdfPath,
  int page,
  Directory workDir,
) async {
  final svgPath = p.join(workDir.path, '${_asciiName(pdfPath)}-p$page.svg');
  final svgFile = File(svgPath);
  if (!svgFile.existsSync()) {
    final r = await Process.run('pdftocairo', ['-svg', '-f', '$page', '-l', '$page', pdfPath, svgPath]);
    if (!svgFile.existsSync()) {
      throw StateError('pdftocairo 실패: $pdfPath p$page\n${r.stderr}');
    }
  }
  final text = svgFile.readAsStringSync();
  final size = _svgSize.firstMatch(text);
  final width = double.parse(size?.group(1) ?? '842');
  final height = double.parse(size?.group(2) ?? '1191');
  final defs = <String, img.Image>{};
  for (final m in _imageDef.allMatches(text)) {
    final decoded = img.decodeImage(base64Decode(m.group(5)!.replaceAll(RegExp(r'\s'), '')));
    if (decoded != null) defs[m.group(1)!] = decoded;
  }
  final placed = <_Placed>[];
  for (final m in _imageUse.allMatches(text)) {
    final image = defs[m.group(1)!];
    if (image == null) continue;
    final t = m.group(2)!.split(',').map((s) => double.parse(s.trim())).toList();
    // matrix(a,b,c,d,e,f): 기울이지 않은 이미지만 다룬다.
    if (t.length != 6 || t[1].abs() > 1e-6 || t[2].abs() > 1e-6) continue;
    placed.add(_Placed(m.group(1)!, image, t[4], t[5], image.width * t[0], image.height * t[3]));
  }
  return (images: placed, width: width, height: height);
}

Future<img.Image> _renderCrop(String pdfPath, int page, _Rect box, Directory workDir) async {
  final base = p.join(workDir.path, '${_asciiName(pdfPath)}-p$page-600');
  final existing = _renderedFile(base);
  if (existing == null) {
    final r = await Process.run('pdftoppm', ['-r', '600', '-gray', '-png', '-f', '$page', '-l', '$page', pdfPath, base]);
    if (_renderedFile(base) == null) {
      throw StateError('pdftoppm 실패: $pdfPath p$page\n${r.stderr}');
    }
  }
  final pageImage = img.decodePng(_renderedFile(base)!.readAsBytesSync())!;
  final x = (box.x * _refPxPerPt).round().clamp(0, pageImage.width - 1);
  final y = (box.y * _refPxPerPt).round().clamp(0, pageImage.height - 1);
  final w = (box.w * _refPxPerPt).round().clamp(1, pageImage.width - x);
  final h = (box.h * _refPxPerPt).round().clamp(1, pageImage.height - y);
  return img.copyCrop(pageImage, x: x, y: y, width: w, height: h);
}

bool _hasInk(img.Image image) {
  var dark = 0;
  for (final px in image) {
    if (px.r < 128 && ++dark > 50) return true;
  }
  return false;
}

/// pdftocairo·pdftoppm 은 한글이 든 출력 파일 이름을 열지 못한다. 중간 파일은 영문 이름으로 둔다.
String _asciiName(String pdfPath) {
  final name = p.basenameWithoutExtension(pdfPath);
  final year = RegExp(r'\d{4}').firstMatch(name)?.group(0) ?? 'x';
  final code = name.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff);
  return 'csat-$year-${code.toRadixString(16)}';
}

File? _renderedFile(String base) {
  final dir = Directory(p.dirname(base));
  final prefix = p.basename(base);
  for (final e in dir.listSync()) {
    if (e is File && p.basename(e.path).startsWith('$prefix-') && e.path.endsWith('.png')) return e;
  }
  return null;
}
