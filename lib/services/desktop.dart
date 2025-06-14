import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

Future<String> _getDataPath() async {
  if (Platform.isWindows) {
    final exePath = Platform.resolvedExecutable;
    final dirPath = path.dirname(exePath);
    final dataPath = path.join(dirPath, 'data');
    
    // data 디렉토리가 없으면 생성
    final dataDir = Directory(dataPath);
    if (!await dataDir.exists()) {
      await dataDir.create();
    }
    return dataPath;
  } else {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }
}

Future<void> saveData(String filename, dynamic data) async {
  final dataPath = await _getDataPath();
  final file = File(path.join(dataPath, filename));
  await file.writeAsString(jsonEncode(data));
}

Future<dynamic> loadData(String filename) async {
  final dataPath = await _getDataPath();
  final file = File(path.join(dataPath, filename));
  
  if (!await file.exists()) {
    throw Exception('File not found: $filename');
  }
  
  final jsonString = await file.readAsString();
  return jsonDecode(jsonString);
} 