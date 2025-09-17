import 'dart:typed_data';
import 'dart:convert';

class AcademySettings {
  final String name;
  final String slogan;
  final int defaultCapacity;
  final int lessonDuration;
  final Uint8List? logo;
  final int sessionCycle; // [추가] 수강 횟수

  AcademySettings({
    required this.name,
    required this.slogan,
    required this.defaultCapacity,
    required this.lessonDuration,
    this.logo,
    this.sessionCycle = 1, // [추가] 기본값 1
  });
} 