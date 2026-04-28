enum AcademicSeasonCode {
  winter('W', 'Winter Session', '겨울방학'),
  spring('S', 'Spring Term', '1학기'),
  summer('U', 'Summer Session', '여름방학'),
  fall('F', 'Fall Term', '2학기');

  const AcademicSeasonCode(this.shortCode, this.englishName, this.koreanName);

  final String shortCode;
  final String englishName;
  final String koreanName;

  static AcademicSeasonCode fromShortCode(String value) {
    final normalized = value.trim().toUpperCase();
    return AcademicSeasonCode.values.firstWhere(
      (code) => code.shortCode == normalized,
      orElse: () => AcademicSeasonCode.spring,
    );
  }
}

class AcademicSeason {
  final int year;
  final AcademicSeasonCode code;

  const AcademicSeason({
    required this.year,
    required this.code,
  });

  factory AcademicSeason.fromDate(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    if (normalized.month <= 2) {
      return AcademicSeason(
          year: normalized.year, code: AcademicSeasonCode.winter);
    }
    if (normalized.month < 7 ||
        (normalized.month == 7 && normalized.day <= 15)) {
      return AcademicSeason(
          year: normalized.year, code: AcademicSeasonCode.spring);
    }
    if (normalized.month == 7 ||
        (normalized.month == 8 && normalized.day <= 15)) {
      return AcademicSeason(
          year: normalized.year, code: AcademicSeasonCode.summer);
    }
    return AcademicSeason(year: normalized.year, code: AcademicSeasonCode.fall);
  }

  String get shortLabel =>
      '${(year % 100).toString().padLeft(2, '0')} ${code.shortCode}';

  String get displayName => '${code.englishName} (${code.koreanName})';

  int get sortOrder => AcademicSeasonCode.values.indexOf(code);
}
