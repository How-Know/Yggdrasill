import 'dart:typed_data';
import 'dart:convert';

class AcademySettings {
  final String name;
  final String slogan;
  final int defaultCapacity;
  final int lessonDuration;
  final Uint8List? logo;

  AcademySettings({
    required this.name,
    required this.slogan,
    required this.defaultCapacity,
    required this.lessonDuration,
    this.logo,
  });
} 