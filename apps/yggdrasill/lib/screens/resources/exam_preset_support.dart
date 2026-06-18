import '../../services/learning_problem_bank_service.dart';
import '../../utils/naesin_exam_context.dart';

const String kExamPresetNaesinLinkConfigKey = 'naesinLinkKey';

class ExamFolderSelection {
  const ExamFolderSelection({
    required this.gradeKey,
    this.school,
    this.isMock = false,
  });

  final String gradeKey;
  final String? school;
  final bool isMock;
}

ExamFolderSelection? parseExamFolderSelection(String? folderId) {
  if (folderId == null || folderId.isEmpty || folderId == '__FAVORITES__') {
    return null;
  }
  if (!folderId.startsWith('exam-folder-')) return null;

  final tail = folderId.substring('exam-folder-'.length);
  if (tail.endsWith('-mock')) {
    final gradeKey = tail.substring(0, tail.length - '-mock'.length);
    if (gradeKey.isEmpty) return null;
    return ExamFolderSelection(gradeKey: gradeKey, isMock: true);
  }
  if (tail.endsWith('-naesin')) {
    final gradeKey = tail.substring(0, tail.length - '-naesin'.length);
    if (gradeKey.isEmpty) return null;
    return ExamFolderSelection(gradeKey: gradeKey);
  }

  final dash = tail.indexOf('-');
  if (dash <= 0 || dash >= tail.length - 1) return null;
  final gradeKey = tail.substring(0, dash);
  final school = tail.substring(dash + 1);
  if (gradeKey.isEmpty || school.isEmpty) return null;
  return ExamFolderSelection(gradeKey: gradeKey, school: school);
}

String naesinLinkKeyOfPreset(LearningProblemDocumentExportPreset preset) {
  return '${preset.renderConfig[kExamPresetNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
      .trim();
}

NaesinLinkSelection? parsedNaesinLinkOfPreset(
  LearningProblemDocumentExportPreset preset,
) {
  return NaesinExamContext.parseNaesinLinkKey(naesinLinkKeyOfPreset(preset));
}

bool presetMatchesExamFolder(
  LearningProblemDocumentExportPreset preset,
  ExamFolderSelection? selection,
) {
  if (selection == null) return false;
  final parsed = parsedNaesinLinkOfPreset(preset);
  if (parsed == null) return false;
  if (parsed.gradeKey != selection.gradeKey) return false;
  if (selection.isMock) return true;
  if (selection.school != null && parsed.school != selection.school) {
    return false;
  }
  return true;
}

int semesterFromCourseKey(String courseKey) {
  final key = courseKey.trim();
  if (key.endsWith('-1') || key.endsWith('-c1')) return 1;
  if (key.endsWith('-2') || key.endsWith('-c2')) return 2;
  return 1;
}

String gradeLabelFromKey(String gradeKey) {
  for (final grade in NaesinExamContext.allGradeOptions()) {
    if (grade.key == gradeKey) return grade.label;
  }
  return gradeKey;
}

String shortExamTermLabel(String examTerm) {
  final normalized = examTerm.trim();
  if (normalized.contains('중간')) return '중간';
  if (normalized.contains('기말')) return '기말';
  return normalized;
}

String formatExamPresetYearShort(int year) => '${year % 100}';

String examPresetCardLine1(NaesinLinkSelection parsed) {
  final year = formatExamPresetYearShort(parsed.year);
  final school = parsed.school.trim();
  final grade = gradeLabelFromKey(parsed.gradeKey);
  if (school.isEmpty) return '$year $grade';
  return '$year $school $grade';
}

String examPresetCardLine2(NaesinLinkSelection parsed) {
  final semester = semesterFromCourseKey(parsed.courseKey);
  final term = shortExamTermLabel(parsed.examTerm);
  return '${semester}학기 $term';
}


List<LearningProblemDocumentExportPreset> filterAndSortExamPresets({
  required List<LearningProblemDocumentExportPreset> presets,
  required ExamFolderSelection? selection,
}) {
  final filtered = presets
      .where((preset) => presetMatchesExamFolder(preset, selection))
      .where((preset) => parsedNaesinLinkOfPreset(preset) != null)
      .toList(growable: false);
  filtered.sort((a, b) {
    final ap = parsedNaesinLinkOfPreset(a)!;
    final bp = parsedNaesinLinkOfPreset(b)!;
    final yearCmp = bp.year.compareTo(ap.year);
    if (yearCmp != 0) return yearCmp;
    final semA = semesterFromCourseKey(ap.courseKey);
    final semB = semesterFromCourseKey(bp.courseKey);
    if (semA != semB) return semA.compareTo(semB);
    final termCmp = ap.examTerm.compareTo(bp.examTerm);
    if (termCmp != 0) return termCmp;
    return naesinLinkKeyOfPreset(a).compareTo(naesinLinkKeyOfPreset(b));
  });
  return filtered;
}
