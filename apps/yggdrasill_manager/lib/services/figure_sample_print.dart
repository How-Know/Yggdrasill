import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 샘플 문항을 실제 인쇄 양식에 올린 결과.
class FigureSampleResult {
  FigureSampleResult({required this.format, required this.pages, required this.pdf, required this.questions, required this.figures});

  final String format;

  /// 쪽마다의 그림 파일(PNG) 자리.
  final List<String> pages;
  final String pdf;
  final int questions;

  /// 그림마다 실제로 실린 크기({id, position, width_em, height_em, scale, source, needs_check}).
  final List<Map<String, dynamic>> figures;

  /// 도형이 많이 줄거나 커져 눈으로 봐야 하는 그림 수(한 그림이 자리마다 따로 적혀 있어 이름으로 센다).
  int get needsCheck => {for (final f in figures) if (f['needs_check'] == true) f['id']}.length;

  factory FigureSampleResult.fromJson(Map<String, dynamic> json) => FigureSampleResult(
        format: json['format'] as String,
        pages: [for (final page in json['pages'] as List) page as String],
        pdf: json['pdf'] as String,
        questions: (json['questions'] as num).toInt(),
        figures: [for (final f in json['figures'] as List? ?? const []) (f as Map).cast<String, dynamic>()],
      );
}

/// 저장소 안에서 앱을 띄웠으면 저장소의 맨 위 폴더를 찾아 준다. 못 찾으면 null.
String? findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory(p.join(dir.path, 'packages', 'ygg_figure')).existsSync() && Directory(p.join(dir.path, 'gateway')).existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

String _tail(Object? text) {
  final lines = '$text'.trim().split('\n');
  return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
}

/// 임시 도구: 폴더의 그림을 [format] 양식의 크기 표대로 다시 그리고, 샘플 문항을 실제 인쇄 틀에 올린다.
///
/// 이 PC 에서 그림 엔진 명령줄 도구와 인쇄 렌더러를 차례로 돌린다(2~3분). 저장소 안에서 띄운 앱에서만 되고,
/// 서버·DB 에는 아무것도 쓰지 않는다. [onStep] 으로 지금 하는 일을 알려 준다.
Future<FigureSampleResult> printFigureSamples({
  required String repoRoot,
  required String figureFolder,
  required String tablePath,
  required String format,
  void Function(String step)? onStep,
}) async {
  final pkg = p.join(repoRoot, 'packages', 'ygg_figure');
  final exportDir = p.join(pkg, 'build', 'export');
  final out = p.join(pkg, 'build', 'samples', format);

  onStep?.call('그림을 이 양식의 크기로 다시 그리는 중… (2분쯤)');
  final export = await Process.run(
    'dart',
    ['run', 'ygg_figure', 'export', figureFolder, '--sizes', tablePath, '--formats', format, '--jobs', '6', '--out', exportDir],
    workingDirectory: pkg,
    runInShell: true,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (export.exitCode != 0) throw StateError('그림을 다시 그리지 못했습니다.\n${_tail(export.stderr)}');

  onStep?.call('샘플 문항을 인쇄 양식에 올리는 중… (30초쯤)');
  final print = await Process.run(
    'node',
    [p.join('tool', 'print_samples.mjs'), format, '--export', exportDir, '--out', out, '--sizes', tablePath],
    workingDirectory: pkg,
    runInShell: true,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final result = File(p.join(out, 'result.json'));
  if (print.exitCode != 0 || !result.existsSync()) throw StateError('인쇄본을 만들지 못했습니다.\n${_tail(print.stderr)}');
  return FigureSampleResult.fromJson(jsonDecode(result.readAsStringSync()) as Map<String, dynamic>);
}
