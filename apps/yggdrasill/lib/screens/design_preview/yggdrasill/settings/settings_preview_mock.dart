/// 설정 Preview 전용 mock 데이터 (프로덕션 서비스·DB 미사용).

class SettingsPreviewMockAcademy {
  final String name;
  final String address;
  final String slogan;
  final String capacity;
  final String lessonDuration;

  const SettingsPreviewMockAcademy({
    this.name = '미르수학학원',
    this.address = '서울시 강남구 테헤란로 123',
    this.slogan = '생각하는 수학',
    this.capacity = '30',
    this.lessonDuration = '50',
  });
}

class SettingsPreviewMockTeacher {
  final String name;
  final String subject;
  final String phone;

  const SettingsPreviewMockTeacher({
    required this.name,
    required this.subject,
    this.phone = '010-0000-0000',
  });
}

const List<SettingsPreviewMockTeacher> kSettingsPreviewMockTeachers = [
  SettingsPreviewMockTeacher(name: '김선생', subject: '수학'),
  SettingsPreviewMockTeacher(name: '이선생', subject: '영어'),
];

const String kSettingsPreviewMockVersion = '1.2.3+456';
const String kSettingsPreviewMockPrinterGeneral = 'HP LaserJet (일반)';
const String kSettingsPreviewMockPrinterNotice = 'Canon (알림장)';
