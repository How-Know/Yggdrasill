import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'storage_service.dart';

class FileStorageService implements StorageService {
  late final String _dataPath;

  FileStorageService._();

  static Future<FileStorageService> create() async {
    final service = FileStorageService._();
    await service._initialize();
    return service;
  }

  Future<void> _initialize() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final dirPath = path.dirname(exePath);
      _dataPath = path.join(dirPath, 'data');
    } else {
      final directory = await getApplicationDocumentsDirectory();
      _dataPath = directory.path;
    }
    
    final dir = Directory(_dataPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  @override
  Future<void> save(String key, String value) async {
    final file = File(path.join(_dataPath, '$key.json'));
    await file.writeAsString(value);
  }

  @override
  Future<String?> load(String key) async {
    final file = File(path.join(_dataPath, '$key.json'));
    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  @override
  Future<void> delete(String key) async {
    final file = File(path.join(_dataPath, '$key.json'));
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Future<StorageService> createPlatformStorageService() async {
  return await FileStorageService.create();
} 