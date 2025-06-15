import 'storage_service_stub.dart'
    if (dart.library.io) 'storage_service_io.dart'
    if (dart.library.html) 'storage_service_web.dart';

abstract class StorageService {
  Future<void> save(String key, String value);
  Future<String?> load(String key);
  Future<void> delete(String key);
}

Future<StorageService> createStorageService() => createPlatformStorageService(); 