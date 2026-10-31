import 'package:supabase_flutter/supabase_flutter.dart';

/// 자료 화면 "고N 모의고사" 폴더용 모의고사 읽기. docs/architecture/mock-exam.md 참고.

const Map<String, String> kMockExamOrgLabels = <String, String>{
  'edu': '교육청',
  'kice': '평가원',
  'csat': '수능',
};

const Map<String, String> kMockExamSectionLabels = <String, String>{
  'common': '공통',
  'probstats': '확률과 통계',
  'calculus': '미적분',
  'geometry': '기하',
};

const List<String> _electiveOrder = <String>[
  'probstats',
  'calculus',
  'geometry'
];

/// 고3: 공통 1~15·선택 23~28 객관식. 고1·2: 1~21 객관식.
bool mockExamIsObjective(int grade, int number) {
  if (grade == 3) return number <= 15 || (number >= 23 && number <= 28);
  return number <= 21;
}

/// 카드 한 장 = 문제지 PDF 한 개. 고3 은 선택과목마다 따로, 고1·2 는 시험당 하나.
class MockExamResourceCard {
  const MockExamResourceCard({
    required this.examId,
    required this.grade,
    required this.examYear,
    required this.month,
    required this.org,
    required this.elective,
    required this.paperId,
    required this.storageBucket,
    required this.storagePath,
  });

  final String examId;
  final int grade;
  final int examYear;
  final int month;
  final String org;

  /// '' 이면 선택과목 없음.
  final String elective;
  final String paperId;
  final String storageBucket;
  final String storagePath;

  String get id => '$examId|$elective';

  String get line1 =>
      '${examYear % 100} $month월 ${kMockExamOrgLabels[org] ?? org}';

  String get line2 =>
      elective.isEmpty ? '' : (kMockExamSectionLabels[elective] ?? elective);

  String get title {
    final base = '$examYear 고$grade $month월 ${kMockExamOrgLabels[org] ?? org}';
    return elective.isEmpty
        ? base
        : '$base (${kMockExamSectionLabels[elective]})';
  }
}

class MockExamResourceItem {
  const MockExamResourceItem({
    required this.section,
    required this.number,
    required this.rawPage,
    required this.region,
    required this.pbQuestionId,
  });

  final String section;
  final int number;
  final int rawPage;

  /// [ymin, xmin, ymax, xmax], 0~1000.
  final List<int> region;
  final String pbQuestionId;
}

class MockExamResourceService {
  MockExamResourceService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<MockExamResourceCard>> listCards({
    required String academyId,
    required int grade,
  }) async {
    final exams = await _client
        .from('mock_exams')
        .select('id, grade, exam_year, exam_month, org')
        .eq('academy_id', academyId)
        .eq('grade', grade)
        .eq('status', 'review');
    final examRows = (exams as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (examRows.isEmpty) return const <MockExamResourceCard>[];
    final papers = await _client
        .from('mock_exam_papers')
        .select('id, exam_id, elective, storage_bucket, storage_path')
        .eq('kind', 'problem')
        .inFilter('exam_id', examRows.map((e) => '${e['id']}').toList());
    final papersByExam = <String, List<Map<String, dynamic>>>{};
    for (final raw in papers as List<dynamic>) {
      final row = Map<String, dynamic>.from(raw as Map);
      papersByExam.putIfAbsent('${row['exam_id']}', () => []).add(row);
    }
    int n(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final cards = <MockExamResourceCard>[];
    for (final exam in examRows) {
      final rows = papersByExam['${exam['id']}'] ?? const [];
      for (final paper in rows) {
        cards.add(
          MockExamResourceCard(
            examId: '${exam['id']}',
            grade: n(exam['grade']),
            examYear: n(exam['exam_year']),
            month: n(exam['exam_month']),
            org: '${exam['org'] ?? ''}',
            elective: '${paper['elective'] ?? ''}',
            paperId: '${paper['id']}',
            storageBucket: '${paper['storage_bucket'] ?? 'problem-documents'}',
            storagePath: '${paper['storage_path'] ?? ''}',
          ),
        );
      }
    }
    cards.sort((a, b) {
      final byYear = b.examYear.compareTo(a.examYear);
      if (byYear != 0) return byYear;
      final byMonth = a.month.compareTo(b.month);
      if (byMonth != 0) return byMonth;
      return _electiveOrder.indexOf(a.elective).compareTo(
            _electiveOrder.indexOf(b.elective),
          );
    });
    return cards;
  }

  /// 카드의 문항: 공통 + 그 카드의 선택과목.
  Future<List<MockExamResourceItem>> listItems(
      MockExamResourceCard card) async {
    final sections = <String>[
      'common',
      if (card.elective.isNotEmpty) card.elective
    ];
    final rows = await _client
        .from('mock_exam_items')
        .select(
            'section, problem_number, raw_page, item_region_1k, pb_question_id')
        .eq('exam_id', card.examId)
        .inFilter('section', sections)
        .order('problem_number', ascending: true);
    final out = <MockExamResourceItem>[];
    for (final raw in rows as List<dynamic>) {
      final row = Map<String, dynamic>.from(raw as Map);
      final region = row['item_region_1k'];
      final page = row['raw_page'];
      if (region is! List || region.length != 4 || page == null) continue;
      out.add(
        MockExamResourceItem(
          section: '${row['section']}',
          number: (row['problem_number'] as num).toInt(),
          rawPage: (page as num).toInt(),
          region: region.map((e) => (e as num).toInt()).toList(growable: false),
          pbQuestionId: '${row['pb_question_id'] ?? ''}'.trim(),
        ),
      );
    }
    return out;
  }

  Future<String> signedPaperUrl(MockExamResourceCard card) => _client.storage
      .from(card.storageBucket)
      .createSignedUrl(card.storagePath, 60 * 60);
}
