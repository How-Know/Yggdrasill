import 'package:path/path.dart' as p;

/// 모의고사 기출. docs/architecture/mock-exam.md 참고.

const List<String> mockExamElectives = <String>[
  'probstats',
  'calculus',
  'geometry',
];

const Map<String, String> mockExamOrgLabels = <String, String>{
  'edu': '교육청',
  'kice': '평가원',
  'csat': '수능',
};

const Map<String, String> mockExamSectionLabels = <String, String>{
  'common': '공통',
  'probstats': '확률과 통계',
  'calculus': '미적분',
  'geometry': '기하',
};

const Map<String, String> mockExamSectionShortLabels = <String, String>{
  'common': '공통',
  'probstats': '확통',
  'calculus': '미적',
  'geometry': '기하',
};

/// 고3 은 공통 1~22, 선택 23~30. 고1·2 는 30문항 모두 공통이다.
List<int> mockExamExpectedNumbers(int grade, String section) {
  if (grade == 3) {
    if (section == 'common') return List<int>.generate(22, (i) => i + 1);
    return List<int>.generate(8, (i) => i + 23);
  }
  if (section != 'common') return const <int>[];
  return List<int>.generate(30, (i) => i + 1);
}

List<String> mockExamSectionsOf(int grade) =>
    grade == 3 ? const <String>['common', ...mockExamElectives] : const <String>['common'];

/// 고3 만 학년도가 시행연도 + 1 이다.
int mockExamSchoolYear(int grade, int examYear) =>
    grade == 3 ? examYear + 1 : examYear;

String mockExamTitle({
  required int examYear,
  required int grade,
  required int month,
  required String org,
}) =>
    '$examYear 고$grade $month월 ${mockExamOrgLabels[org] ?? org}';

class MockExamFileName {
  const MockExamFileName({
    required this.path,
    required this.examYear,
    required this.grade,
    required this.month,
    required this.org,
    required this.elective,
    required this.kind,
  });

  final String path;
  final int examYear;
  final int grade;
  final int month;
  final String org;

  /// '' 이면 선택과목 없음(고1·2).
  final String elective;

  /// 'problem' | 'solution'
  final String kind;

  String get examKey => '$grade|$examYear|$month|$org';
  String get paperKey => '$examKey|$kind|$elective';
  String get title =>
      mockExamTitle(examYear: examYear, grade: grade, month: month, org: org);
}

const Map<String, String> _orgByLabel = <String, String>{
  '교육청': 'edu',
  '평가원': 'kice',
  '수능': 'csat',
};

String _electiveOf(String raw) {
  final s = raw.replaceAll(RegExp(r'\s+'), '');
  if (s.startsWith('확')) return 'probstats';
  if (s.startsWith('미')) return 'calculus';
  if (s.startsWith('기')) return 'geometry';
  return '';
}

final RegExp _mockFileRe = RegExp(
  r'^(\d{4})\s*고\s*([123])\s*(\d{1,2})\s*월\s*(교육청|평가원|수능)'
  r'\s*(?:\(\s*(확통|확률과\s*통계|미적분?|기하)\s*\))?'
  r'\s*(?:[-_]\s*(해설))?\s*$',
);

/// `2024 고3 11월 수능 (확통) - 해설.pdf` 같은 이름을 읽는다. 형식이 다르면 null.
MockExamFileName? parseMockExamFileName(String path) {
  if (p.extension(path).toLowerCase() != '.pdf') return null;
  final stem = p.basenameWithoutExtension(path).trim();
  final m = _mockFileRe.firstMatch(stem);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final grade = int.parse(m.group(2)!);
  final month = int.parse(m.group(3)!);
  if (month < 1 || month > 12) return null;
  final elective = _electiveOf(m.group(5) ?? '');
  if (grade == 3 && elective.isEmpty) return null;
  if (grade != 3 && elective.isNotEmpty) return null;
  return MockExamFileName(
    path: path,
    examYear: year,
    grade: grade,
    month: month,
    org: _orgByLabel[m.group(4)!]!,
    elective: elective,
    kind: m.group(6) == null ? 'problem' : 'solution',
  );
}

int _int(dynamic v, [int fallback = 0]) =>
    v is num ? v.toInt() : int.tryParse('$v') ?? fallback;

List<int>? _region(dynamic v) {
  if (v is! List || v.length != 4) return null;
  final out = v.map((e) => _int(e, -1)).toList(growable: false);
  return out.any((e) => e < 0) ? null : out;
}

class MockExam {
  const MockExam({
    required this.id,
    required this.grade,
    required this.examYear,
    required this.schoolYear,
    required this.month,
    required this.org,
    required this.title,
    required this.status,
    required this.stage,
    required this.progress,
    required this.lastError,
    required this.updatedAt,
  });

  final String id;
  final int grade;
  final int examYear;
  final int? schoolYear;
  final int month;
  final String org;
  final String title;
  final String status;
  final String stage;
  final Map<String, dynamic> progress;
  final String lastError;
  final DateTime? updatedAt;

  String get displayTitle => title.trim().isNotEmpty
      ? title
      : mockExamTitle(examYear: examYear, grade: grade, month: month, org: org);

  bool get isBusy => status == 'queued' || status == 'running';

  /// 진행 메모의 구간별 누락 목록. {section: {crop:[], answer:[], solution:[]}}
  Map<String, Map<String, List<int>>> get missing {
    final raw = progress['missing'];
    if (raw is! Map) return const <String, Map<String, List<int>>>{};
    final out = <String, Map<String, List<int>>>{};
    raw.forEach((section, value) {
      if (value is! Map) return;
      out['$section'] = <String, List<int>>{
        for (final key in const <String>['crop', 'answer', 'solution'])
          key: value[key] is List
              ? (value[key] as List).map((e) => _int(e)).toList()
              : const <int>[],
      };
    });
    return out;
  }

  int get missingCount => missing.values
      .expand((m) => m.values)
      .fold<int>(0, (sum, list) => sum + list.length);

  factory MockExam.fromMap(Map<String, dynamic> map) => MockExam(
        id: '${map['id']}',
        grade: _int(map['grade']),
        examYear: _int(map['exam_year']),
        schoolYear: map['school_year'] == null ? null : _int(map['school_year']),
        month: _int(map['exam_month']),
        org: '${map['org'] ?? ''}',
        title: '${map['title'] ?? ''}',
        status: '${map['status'] ?? ''}',
        stage: '${map['stage'] ?? ''}',
        progress: map['progress'] is Map
            ? Map<String, dynamic>.from(map['progress'] as Map)
            : const <String, dynamic>{},
        lastError: '${map['last_error'] ?? ''}',
        updatedAt: DateTime.tryParse('${map['updated_at'] ?? ''}'),
      );
}

class MockExamPaper {
  const MockExamPaper({
    required this.id,
    required this.kind,
    required this.elective,
    required this.storageBucket,
    required this.storagePath,
    required this.fileName,
    required this.pageCount,
  });

  final String id;
  final String kind;
  final String elective;
  final String storageBucket;
  final String storagePath;
  final String fileName;
  final int? pageCount;

  factory MockExamPaper.fromMap(Map<String, dynamic> map) => MockExamPaper(
        id: '${map['id']}',
        kind: '${map['kind'] ?? ''}',
        elective: '${map['elective'] ?? ''}',
        storageBucket: '${map['storage_bucket'] ?? 'problem-documents'}',
        storagePath: '${map['storage_path'] ?? ''}',
        fileName: '${map['file_name'] ?? ''}',
        pageCount: map['page_count'] == null ? null : _int(map['page_count']),
      );
}

class MockExamItem {
  const MockExamItem({
    required this.id,
    required this.section,
    required this.number,
    required this.paperId,
    required this.rawPage,
    required this.itemRegion,
    required this.answerKind,
    required this.answerText,
    required this.answerSource,
    required this.solutionPaperId,
    required this.solutionRawPage,
    required this.solutionNumberRegion,
    required this.solutionContentRegion,
    required this.pbQuestionId,
  });

  final String id;
  final String section;
  final int number;
  final String? paperId;
  final int? rawPage;

  /// [ymin, xmin, ymax, xmax], 0~1000.
  final List<int>? itemRegion;
  final String answerKind;
  final String answerText;
  final String answerSource;
  final String? solutionPaperId;
  final int? solutionRawPage;
  final List<int>? solutionNumberRegion;
  final List<int>? solutionContentRegion;
  final String? pbQuestionId;

  bool get hasCrop => paperId != null && rawPage != null && itemRegion != null;
  bool get hasAnswer => answerText.trim().isNotEmpty;
  bool get hasSolution => solutionPaperId != null && solutionRawPage != null;

  static String? _id(dynamic v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }

  factory MockExamItem.fromMap(Map<String, dynamic> map) => MockExamItem(
        id: '${map['id']}',
        section: '${map['section'] ?? ''}',
        number: _int(map['problem_number']),
        paperId: _id(map['paper_id']),
        rawPage: map['raw_page'] == null ? null : _int(map['raw_page']),
        itemRegion: _region(map['item_region_1k']),
        answerKind: '${map['answer_kind'] ?? ''}',
        answerText: '${map['answer_text'] ?? ''}',
        answerSource: '${map['answer_source'] ?? 'vlm'}',
        solutionPaperId: _id(map['solution_paper_id']),
        solutionRawPage: map['solution_raw_page'] == null
            ? null
            : _int(map['solution_raw_page']),
        solutionNumberRegion: _region(map['solution_number_region_1k']),
        solutionContentRegion: _region(map['solution_content_region_1k']),
        pbQuestionId: _id(map['pb_question_id']),
      );
}

class MockExamSectionLink {
  const MockExamSectionLink({
    required this.section,
    required this.pbDocumentId,
    required this.extractJobId,
    required this.extractStatus,
    required this.documentStatus,
  });

  final String section;
  final String? pbDocumentId;
  final String? extractJobId;

  /// pb_extract_jobs.status. 작업이 없으면 ''.
  final String extractStatus;

  /// pb_documents.status. 문서가 없으면 ''.
  final String documentStatus;
}

/// 고3: 공통 1~15·선택 23~28 객관식. 고1·2: 1~21 객관식.
bool mockExamIsObjective(int grade, int number) {
  if (grade == 3) return number <= 15 || (number >= 23 && number <= 28);
  return number <= 21;
}

/// 정답 입력을 저장 형태로 맞춘다. 객관식 문항의 1~5 는 원문자로 바꾼다.
({String kind, String text})? normalizeMockAnswerInput(
  String raw, {
  required bool objective,
}) {
  const circled = <String>['①', '②', '③', '④', '⑤'];
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (circled.contains(s)) return (kind: 'objective', text: s);
  final n = int.tryParse(s);
  if (n == null || n < 0) return null;
  if (objective) {
    if (n < 1 || n > 5) return null;
    return (kind: 'objective', text: circled[n - 1]);
  }
  return (kind: 'subjective', text: '$n');
}
