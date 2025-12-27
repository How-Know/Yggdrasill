import 'dart:html' as html;

import 'storage_service.dart';

class WebStorageService implements StorageService {
  @override
  Future<void> save(String key, String value) async {
    html.window.localStorage[key] = value;
  }

  @override
  Future<String?> load(String key) async {
    return html.window.localStorage[key];
  }

  @override
  Future<void> delete(String key) async {
    html.window.localStorage.remove(key);
  }
}

Future<StorageService> createPlatformStorageService() async {
  return WebStorageService();
}

