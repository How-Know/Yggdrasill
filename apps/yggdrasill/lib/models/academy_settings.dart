import 'dart:typed_data';

class AcademySettings {
  final String name;
  final String slogan;
  final String address;
  final int defaultCapacity;
  final int lessonDuration;
  final Uint8List? logo;
  final int sessionCycle; // [추가] 수강 횟수
  /// 로컬·서버 시험 일정의 현재 시즌(정수). academy_settings.active_exam_season_id 와 동기.
  final int activeExamSeasonId;

  AcademySettings({
    required this.name,
    required this.slogan,
    this.address = '',
    required this.defaultCapacity,
    required this.lessonDuration,
    this.logo,
    this.sessionCycle = 1, // [추가] 기본값 1
    this.activeExamSeasonId = 1,
  });
}
