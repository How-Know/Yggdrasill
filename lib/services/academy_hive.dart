import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/academy_settings.dart';

class AcademyHiveService {
  static const String boxName = 'academy_settings_box';
  static const String key = 'academy_settings';

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(boxName);
  }

  static Future<void> saveAcademySettings(AcademySettings settings, String paymentType) async {
    final box = Hive.box(boxName);
    await box.put(key, {
      'name': settings.name,
      'slogan': settings.slogan,
      'default_capacity': settings.defaultCapacity,
      'lesson_duration': settings.lessonDuration,
      'payment_type': paymentType,
      'logo': settings.logo,
    });
  }

  static Map<String, dynamic>? getAcademySettings() {
    final box = Hive.box(boxName);
    final data = box.get(key);
    if (data != null) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }
} 