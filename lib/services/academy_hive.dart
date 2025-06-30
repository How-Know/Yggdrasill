import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/academy_settings.dart';
import '../models/operating_hours.dart';
import '../models/student.dart';

class AcademyHiveService {
  static const String boxName = 'academy_settings_box';
  static const String key = 'academy_settings';
  static const String operatingHoursBox = 'operating_hours_box';
  static const String operatingHoursKey = 'operating_hours';
  static const String studentsBox = 'students_box';
  static const String studentsKey = 'students';

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(boxName);
    await Hive.openBox(studentsBox);
    await Hive.openBox(operatingHoursBox);
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

  static Future<void> saveOperatingHours(List hours) async {
    final box = Hive.box(operatingHoursBox);
    await box.put(operatingHoursKey, hours.map((h) => h.toJson()).toList());
  }

  static List<OperatingHours> getOperatingHours() {
    final box = Hive.box(operatingHoursBox);
    final data = box.get(operatingHoursKey);
    if (data != null) {
      return (data as List).map((e) => OperatingHours.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    return [];
  }

  static Future<void> saveStudents(List students) async {
    if (!Hive.isBoxOpen(studentsBox)) {
      await Hive.openBox(studentsBox);
    }
    final box = Hive.box(studentsBox);
    await box.put(studentsKey, students.map((s) => s.toJson()).toList());
  }

  static Future<List<Student>> getStudents() async {
    if (!Hive.isBoxOpen(studentsBox)) {
      await Hive.openBox(studentsBox);
    }
    final box = Hive.box(studentsBox);
    final data = box.get(studentsKey);
    if (data != null) {
      return (data as List).map((e) => Student.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    return [];
  }
} 