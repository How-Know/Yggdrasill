import 'storage_service.dart';

Future<StorageService> createPlatformStorageService() {
  throw UnsupportedError(
    'Cannot create a storage service without dart:io or dart:html.',
  );
} 