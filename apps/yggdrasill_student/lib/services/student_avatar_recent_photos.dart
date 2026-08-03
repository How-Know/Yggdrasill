import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'student_api.dart';

/// 프로필 사진 최근 사용분 (기기 로컬, 최대 3개, MRU).
class StudentAvatarRecentPhotos {
  StudentAvatarRecentPhotos._();
  static final StudentAvatarRecentPhotos instance =
      StudentAvatarRecentPhotos._();

  static const maxCount = 3;

  Future<Directory> _dirForStudent(String studentId) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/avatar_recents/$studentId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _studentKey() async {
    final id = await StudentApi.instance.identity();
    final sid = (id?.studentId ?? '').trim();
    return sid.isEmpty ? '_local' : sid;
  }

  Future<List<Uint8List>> load() async {
    try {
      final key = await _studentKey();
      final dir = await _dirForStudent(key);
      final out = <Uint8List>[];
      for (var i = 0; i < maxCount; i++) {
        final file = File('${dir.path}/recent_$i.jpg');
        if (!await file.exists()) break;
        out.add(await file.readAsBytes());
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 맨 앞에 넣고 최대 [maxCount]개 유지. 동일 바이트면 맨 앞으로만 이동.
  Future<List<Uint8List>> push(Uint8List bytes) async {
    final key = await _studentKey();
    final dir = await _dirForStudent(key);
    final current = await load();
    final next = <Uint8List>[
      bytes,
      ...current.where((b) => !sameBytes(b, bytes)),
    ].take(maxCount).toList();

    for (var i = 0; i < maxCount; i++) {
      final file = File('${dir.path}/recent_$i.jpg');
      if (i < next.length) {
        await file.writeAsBytes(next[i], flush: true);
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    return next;
  }

  static bool sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    // 짧은 샘플 비교로 충분 (프로필 썸네일 수준).
    final step = (a.length / 32).ceil().clamp(1, a.length);
    for (var i = 0; i < a.length; i += step) {
      if (a[i] != b[i]) return false;
    }
    return a[a.length - 1] == b[b.length - 1];
  }
}
