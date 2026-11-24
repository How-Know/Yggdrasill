import 'dart:io';

import 'package:path/path.dart' as p;

import '../raster/gray_map.dart';
import '../scene.dart';
import '../tikz.dart';

/// 그림 한 장을 PDF 로 조판한다. xelatex 이 PATH 에 있어야 한다.
Future<File> renderPdf(Scene scene, Directory outDir, String name) async {
  outDir.createSync(recursive: true);
  final tex = File(p.join(outDir.path, '$name.tex'))..writeAsStringSync(standaloneDocument(scene));
  final r = await Process.run(
    'xelatex',
    ['-interaction=nonstopmode', '-halt-on-error', '$name.tex'],
    workingDirectory: outDir.path,
  );
  final pdf = File(p.join(outDir.path, '$name.pdf'));
  if (r.exitCode != 0 || !pdf.existsSync()) {
    final log = '${r.stdout}'.split('\n').where((l) => l.startsWith('!') || l.startsWith('l.')).take(6).join('\n');
    throw StateError('조판 실패(${tex.path})\n$log');
  }
  for (final ext in ['aux', 'log']) {
    final f = File(p.join(outDir.path, '$name.$ext'));
    if (f.existsSync()) f.deleteSync();
  }
  return pdf;
}

/// PDF 를 주어진 해상도의 흑백 그림으로 찍는다. pdftoppm 이 PATH 에 있어야 한다.
Future<File> rasterize(File pdf, double ppi) async {
  final base = p.withoutExtension(pdf.path);
  final r = await Process.run('pdftoppm', ['-r', ppi.toStringAsFixed(2), '-gray', '-png', '-singlefile', pdf.path, base]);
  final png = File('$base.png');
  if (r.exitCode != 0 || !png.existsSync()) throw StateError('그림 찍기 실패: ${r.stderr}');
  return png;
}

Future<GrayMap> renderGray(Scene scene, Directory outDir, String name, double ppi) async {
  final png = await rasterize(await renderPdf(scene, outDir, name), ppi);
  return GrayMap.readPng(png.path);
}
