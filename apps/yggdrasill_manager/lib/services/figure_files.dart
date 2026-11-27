import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ygg_figure/ygg_figure.dart';

/// 그림 편집기가 여는 폴더: 그림 파일(.json)들과 크기 표 하나.
///
/// 그림은 이 PC 의 파일로만 읽고 쓴다. 서버·DB 에는 아무것도 보내지 않는다.
class FigureFolder {
  FigureFolder({required this.path, required this.files, required this.table, required this.tablePath, required this.tableOnDisk});

  final String path;

  /// 그림 파일 이름(확장자 포함), 이름순.
  final List<String> files;
  FigureSizeTable table;

  /// 크기 표를 저장할 자리.
  final String tablePath;

  /// 크기 표 파일이 이미 있었는가(없으면 기본값으로 시작한 것이다).
  final bool tableOnDisk;

  String fileOf(String name) => p.join(path, name);
}

const _tableName = 'size_table.json';

/// 표 파일이 없을 때 시작하는 값. 사장님이 화면에서 보고 고쳐 저장하면 그 값이 표가 된다.
FigureSizeTable defaultFigureSizeTable() => FigureSizeTable([
      for (final f in figureFormats)
        for (final pos in figurePositions) FigureSlot(format: f, position: pos, widthEm: pos == 'inline-right' ? 10 : 16),
    ]);

FigureFolder openFigureFolder(String path) {
  final dir = Directory(path);
  final files = <String>[];
  for (final f in dir.listSync().whereType<File>()) {
    final name = p.basename(f.path);
    if (!name.endsWith('.json') || name == _tableName) continue;
    try {
      final doc = jsonDecode(f.readAsStringSync());
      if (doc is Map && doc['format'] == figureFormat) files.add(name);
    } on FormatException {
      // 그림 파일이 아닌 json 은 목록에 넣지 않는다.
    }
  }
  files.sort();
  // 크기 표는 이 폴더, 없으면 바로 위 폴더에서 찾는다(여러 그림 폴더가 표 하나를 같이 쓴다).
  final here = File(p.join(path, _tableName)), above = File(p.join(dir.parent.path, _tableName));
  final found = here.existsSync() ? here : (above.existsSync() ? above : null);
  final table = found == null
      ? defaultFigureSizeTable()
      : FigureSizeTable.fromJson(jsonDecode(found.readAsStringSync()) as Map<String, dynamic>);
  return FigureFolder(path: path, files: files, table: table, tablePath: (found ?? here).path, tableOnDisk: found != null);
}

Map<String, dynamic> readFigureFile(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void writeFigureFile(String path, Map<String, dynamic> doc) => File(path).writeAsStringSync(formatFigureJson(doc));

void writeFigureSizeTable(String path, FigureSizeTable table) {
  final b = StringBuffer('{\n  "format": "${FigureSizeTable.sizeTableFormat}",\n');
  if (table.columns.isNotEmpty) b.write('  "columns": ${jsonEncode(table.columns)},\n');
  b.write('  "slots": [\n');
  b.write(table.slots.map((s) => '    ${jsonEncode(s.toJson())}').join(',\n'));
  b.write('\n  ]\n}\n');
  File(path).writeAsStringSync(b.toString());
}

/// 저장소 안에서 앱을 띄웠으면 엔진의 수능 그림 폴더를 찾아 준다. 못 찾으면 null.
String? findRepoFigureFolder() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory(p.join(dir.path, 'packages', 'ygg_figure', 'figures', 'csat'));
    if (candidate.existsSync()) return candidate.path;
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

/// 새 그림의 빈 그림판(60×45mm, 가운데가 원점, 단위 10mm).
Map<String, dynamic> newFigureDoc() => <String, dynamic>{
      'format': figureFormat,
      'style': 'csat-2026.2',
      'canvas': <String, dynamic>{
        'width': 60.0,
        'height': 45.0,
        'origin': <dynamic>[30.0, 22.5],
        'unit': 10.0,
      },
      'objects': <dynamic>[],
    };
