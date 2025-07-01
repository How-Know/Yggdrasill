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
    // json 파일 저장/불러오기 관련 코드가 있다면 모두 삭제. SQLite 단일화에 맞게 정리.
  }

  @override
  Future<String?> load(String key) async {
    // json 파일 저장/불러오기 관련 코드가 있다면 모두 삭제. SQLite 단일화에 맞게 정리.
    return null;
  }

  @override
  Future<void> delete(String key) async {
    // json 파일 저장/불러오기 관련 코드가 있다면 모두 삭제. SQLite 단일화에 맞게 정리.
  }
}

Future<StorageService> createPlatformStorageService() async {
  return await FileStorageService.create();
} 