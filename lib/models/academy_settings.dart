class AcademySettings {
  final String name;
  final String slogan;
  final int defaultCapacity;
  final int lessonDuration;

  AcademySettings({
    required this.name,
    required this.slogan,
    required this.defaultCapacity,
    required this.lessonDuration,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'slogan': slogan,
      'defaultCapacity': defaultCapacity,
      'lessonDuration': lessonDuration,
    };
  }

  factory AcademySettings.fromJson(Map<String, dynamic> json) {
    return AcademySettings(
      name: json['name'] as String? ?? '',
      slogan: json['slogan'] as String? ?? '',
      defaultCapacity: json['defaultCapacity'] as int? ?? 30,
      lessonDuration: json['lessonDuration'] as int? ?? 50,
    );
  }

  factory AcademySettings.defaults() {
    return AcademySettings(
      name: '',
      slogan: '',
      defaultCapacity: 30,
      lessonDuration: 50,
    );
  }
} 