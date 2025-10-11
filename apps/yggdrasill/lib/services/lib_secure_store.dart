import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  // Android EncryptedSharedPreferences, iOS Keychain, Windows DPAPI 등 OS 보안 저장소 사용
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  Future<void> saveRefreshToken({required String academyId, required String email, required String refreshToken}) async {
    final key = 'rt:$academyId:${email.toLowerCase()}';
    await _storage.write(key: key, value: refreshToken, aOptions: const AndroidOptions(encryptedSharedPreferences: true));
  }

  Future<String?> loadRefreshToken({required String academyId, required String email}) async {
    final key = 'rt:$academyId:${email.toLowerCase()}';
    return await _storage.read(key: key, aOptions: const AndroidOptions(encryptedSharedPreferences: true));
  }

  Future<void> deleteRefreshToken({required String academyId, required String email}) async {
    final key = 'rt:$academyId:${email.toLowerCase()}';
    await _storage.delete(key: key, aOptions: const AndroidOptions(encryptedSharedPreferences: true));
  }
}





