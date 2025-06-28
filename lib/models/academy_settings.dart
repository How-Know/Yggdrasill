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

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'slogan': slogan,
      'defaultCapacity': defaultCapacity,
      'lessonDuration': lessonDuration,
      'logo': logo != null ? base64Encode(logo!) : null,
    };
  }

  factory AcademySettings.fromJson(Map<String, dynamic> json) {
    return AcademySettings(
      name: json['name'] as String? ?? '',
      slogan: json['slogan'] as String? ?? '',
      defaultCapacity: json['defaultCapacity'] as int? ?? 30,
      lessonDuration: json['lessonDuration'] as int? ?? 50,
      logo: json['logo'] != null && json['logo'] is String && (json['logo'] as String).isNotEmpty
          ? base64Decode(json['logo'] as String)
          : null,
    );
  }

  factory AcademySettings.defaults() {
    return AcademySettings(
      name: '',
      slogan: '',
      defaultCapacity: 30,
      lessonDuration: 50,
      logo: null,
    );
  }
} 