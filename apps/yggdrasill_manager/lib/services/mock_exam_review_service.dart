import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/problem_bank/mock_exam/mock_exam_models.dart';
import 'mock_exam_service.dart';
import 'problem_bank_service.dart';
import 'textbook_workflow_runner.dart';
import 'textbook_workflow_service.dart';

/// 모의고사 구간의 검수 진행 상태(교재 메뉴 목록 표시용)
enum MockExamReviewStage {
  /// 아직 검수를 시작하지 않았다.
  notStarted,

  /// 추출·AI 검수가 돌고 있다(또는 앱을 닫아 멈춘 채 남았다).
  running,
  failed,

  /// 중간에 멈췄다.
  stopped,

  /// AI 검수가 끝나 사람이 볼 차례다.
  reviewing,
  confirmed,
}

/// 회차의 구간 하나(공통·선택과목)와 검수 작업 상태. 검수의 책 id 는 구간의 문제은행 문서 id 와 같다.
class MockExamReviewSection {
  const MockExamReviewSection({
    required this.section,
    this.documentId,
    this.publishOnConfirm = false,
    this.workflow,
    this.sharedSlotCount = 0,
  });

  /// common | probstats | calculus | geometry | ga | na
  final String section;

  /// 이 구간의 자리 가운데 다른 구간(가형↔나형)의 문항을 가리키는 자리 수. 그 문항은 이 구간의 검수 목록에 없다.
  final int sharedSlotCount;

  /// 구간 줄에 붙이는 짧은 안내(예: 나형 줄의 "가형 공통 4"). 없으면 빈 문자열.
  String get sharedSlotNote {
    final other = switch (section) { 'ga' => 'na', 'na' => 'ga', _ => '' };
    if (sharedSlotCount <= 0 || other.isEmpty) return '';
    return '${mockExamSectionLabels[other] ?? other} 공통 $sharedSlotCount';
  }

  /// 구간의 문제은행 문서. 추출도 검수 시작도 하지 않은 구간은 null.
  final String? documentId;

  /// 검수에서 만든 구간이라 문항이 아직 학습앱에 나가지 않았다(구간을 확정할 때 공개한다).
  final bool publishOnConfirm;
  final TextbookSubunitWorkflow? workflow;

  String get label => mockExamSectionLabels[section] ?? section;

  MockExamReviewStage get stage {
    final wf = workflow;
    if (wf != null && wf.isConfirmed) return MockExamReviewStage.confirmed;
    if (wf == null || wf.workOrder == null) return MockExamReviewStage.notStarted;
    return switch (wf.pipelineStatus) {
      'queued' || 'running' => MockExamReviewStage.running,
      'failed' => MockExamReviewStage.failed,
      'done' => MockExamReviewStage.reviewing,
      _ => MockExamReviewStage.stopped,
    };
  }
}

/// 회차 하나와 검수할 구간들(문제지가 올라온 구간과 이미 문서가 있는 구간).
class MockExamReviewExam {
  const MockExamReviewExam({
    required this.exam,
    required this.sections,
    this.problemPaperCount = 0,
    this.solutionPaperCount = 0,
  });

  final MockExam exam;
  final List<MockExamReviewSection> sections;

  /// 올라온 문제지·해설 PDF 수
  final int problemPaperCount;
  final int solutionPaperCount;

  String get id => exam.id;

  /// 업로드 창이 같은 회차를 가리는 키([MockExamFileName.examKey] 와 같다)
  String get examKey => '${exam.grade}|${exam.examYear}|${exam.month}|${exam.org}';
  String get title => exam.displayTitle;
  int get grade => exam.grade;

  /// 아직 한 번도 추출하지 않은 회차(문제지·해설 PDF 만 올라와 있다).
  bool get notExtracted => exam.status == 'draft' || exam.status.isEmpty;

  /// 검수를 시작하지 않은 구간
  List<MockExamReviewSection> get notStartedSections =>
      [for (final s in sections) if (s.stage == MockExamReviewStage.notStarted) s];

  int get confirmedCount => sections.where((s) => s.stage == MockExamReviewStage.confirmed).length;

  /// 이 회차에 속한 구간 작업들
  Iterable<TextbookSubunitWorkflow> get workflows => [
        for (final s in sections)
          if (s.workflow != null) s.workflow!,
      ];
}

/// 회차에 있어야 할 구간: 문제지가 있으면 공통, 고3 은 문제지가 올라온 선택과목, 그리고 이미 문서가 있는 구간
/// (게이트웨이 mockExpectedSections 와 같은 규칙). 가형·나형 회차는 공통 없이 문제지가 올라온 유형마다 구간 하나다.
List<String> mockExamReviewSections({
  required int grade,
  required Iterable<MockExamPaper> papers,
  Iterable<String> linkedSections = const [],
}) {
  final found = <String>{...linkedSections};
  final problems = [for (final p in papers) if (p.kind == 'problem') p];
  if (grade == 3) {
    final electives = [
      for (final p in problems)
        if (mockExamElectives.contains(p.elective)) p.elective,
    ];
    if (electives.isNotEmpty) {
      found
        ..add('common')
        ..addAll(electives);
    }
    for (final p in problems) {
      if (mockExamLegacyTypes.contains(p.elective)) found.add(p.elective);
    }
  } else if (problems.isNotEmpty) {
    found.add('common');
  }
  return [
    for (final s in const ['common', ...mockExamElectives, ...mockExamLegacyTypes])
      if (found.contains(s)) s,
  ];
}

/// 모의고사 업로드·검수 시작 결과(회차별)
class MockExamReviewStartResult {
  const MockExamReviewStartResult({
    required this.examId,
    required this.title,
    required this.grade,
    required this.started,
    this.extractionRequested = false,
  });

  final String examId;
  final String title;
  final int grade;

  /// 검수 대기열에 넣은 구간 수
  final int started;

  /// 이번에 회차 추출을 걸었는가
  final bool extractionRequested;
}

/// 교재 메뉴의 모의고사: 학년별 회차·구간 목록, 업로드(추출 시작), 검수 시작.
/// 검수는 시중교재와 같은 실행기([TextbookWorkflowRunner])와 작업 화면을 쓴다.
class MockExamReviewService {
  MockExamReviewService({
    SupabaseClient? client,
    ProblemBankService? problemBank,
    MockExamService? mockExams,
    TextbookWorkflowService? workflows,
    TextbookWorkflowRunner? runner,
  })  : _db = client ?? Supabase.instance.client,
        _pb = problemBank ?? ProblemBankService(client: client),
        _mock = mockExams ?? MockExamService(client: client),
        _workflows = workflows ?? TextbookWorkflowService(client: client),
        _runner = runner ?? TextbookWorkflowRunner.instance;

  final SupabaseClient _db;
  final ProblemBankService _pb;
  final MockExamService _mock;
  final TextbookWorkflowService _workflows;

  /// 검수를 돌리는 실행기. 앱에서는 앱 전역 실행기다.
  final TextbookWorkflowRunner _runner;

  Future<String> resolveAcademyId() => _pb.resolveAcademyId();

  /// 구간 문서 연결과 공개 대기 여부. exam_id → section → (문서 id, 확정 때 공개)
  Future<Map<String, Map<String, ({String documentId, bool publishOnConfirm})>>> _sectionDocuments(
    String academyId,
  ) async {
    const pageSize = 1000;
    final links = <Map<String, dynamic>>[];
    for (var from = 0;; from += pageSize) {
      final page = await _db
          .from('mock_exam_sections')
          .select('exam_id,section,pb_document_id')
          .eq('academy_id', academyId)
          .order('exam_id', ascending: true)
          .order('section', ascending: true)
          .range(from, from + pageSize - 1);
      final rows = [for (final r in (page as List).whereType<Map>()) Map<String, dynamic>.from(r)];
      links.addAll(rows);
      if (rows.length < pageSize) break;
    }
    final ids = <String>{
      for (final l in links)
        if ('${l['pb_document_id'] ?? ''}'.trim().isNotEmpty) '${l['pb_document_id']}'.trim(),
    }.toList();
    final pending = <String>{};
    for (var i = 0; i < ids.length; i += 150) {
      final chunk = ids.sublist(i, (i + 150).clamp(0, ids.length));
      final docs = await _db.from('pb_documents').select('id,mock_review:meta->mock_review').inFilter('id', chunk);
      for (final d in (docs as List).whereType<Map>()) {
        if (mockReviewPending(d['mock_review'])) pending.add('${d['id']}');
      }
    }
    final out = <String, Map<String, ({String documentId, bool publishOnConfirm})>>{};
    for (final l in links) {
      final documentId = '${l['pb_document_id'] ?? ''}'.trim();
      if (documentId.isEmpty) continue;
      out.putIfAbsent('${l['exam_id']}', () => {})['${l['section']}'] =
          (documentId: documentId, publishOnConfirm: pending.contains(documentId));
    }
    return out;
  }

  /// `pb_documents.meta.mock_review` 가 "확정할 때 공개"이고 아직 공개하지 않았는가(게이트웨이 mockReviewPending 과 같다).
  static bool mockReviewPending(Object? mockReview) {
    if (mockReview is! Map) return false;
    return mockReview['publish_on_confirm'] == true && '${mockReview['published_at'] ?? ''}'.trim().isEmpty;
  }

  /// 회차 → 구간 → 다른 구간의 문항을 가리키는 자리 수. 읽지 못하면 안내만 빠진다.
  Future<Map<String, Map<String, int>>> _sharedSlotCounts(String academyId) async {
    final out = <String, Map<String, int>>{};
    try {
      final rows = await _db
          .from('mock_exam_items')
          .select('exam_id, section')
          .eq('academy_id', academyId)
          .not('merged_at', 'is', null);
      for (final row in rows as List<dynamic>) {
        final examId = '${(row as Map)['exam_id'] ?? ''}';
        final section = '${row['section'] ?? ''}';
        final bySection = out.putIfAbsent(examId, () => <String, int>{});
        bySection[section] = (bySection[section] ?? 0) + 1;
      }
    } catch (_) {
      return const {};
    }
    return out;
  }

  /// 회차 목록(최근 연도 → 월)과 구간별 검수 상태
  Future<List<MockExamReviewExam>> fetchExams(String academyId) async {
    final (exams, papers, documents, workflows, shared) = await (
      _mock.listExams(academyId),
      _mock.listPapersByExam(academyId),
      _sectionDocuments(academyId),
      _workflows.fetchMockExams(academyId),
      _sharedSlotCounts(academyId),
    ).wait;
    return [
      for (final exam in exams)
        MockExamReviewExam(
          exam: exam,
          problemPaperCount: (papers[exam.id] ?? const []).where((p) => p.kind == 'problem').length,
          solutionPaperCount: (papers[exam.id] ?? const []).where((p) => p.kind == 'solution').length,
          sections: [
            for (final section in mockExamReviewSections(
              grade: exam.grade,
              papers: papers[exam.id] ?? const [],
              linkedSections: documents[exam.id]?.keys ?? const [],
            ))
              MockExamReviewSection(
                section: section,
                documentId: documents[exam.id]?[section]?.documentId,
                publishOnConfirm: documents[exam.id]?[section]?.publishOnConfirm ?? false,
                workflow: workflows[documents[exam.id]?[section]?.documentId],
                sharedSlotCount: shared[exam.id]?[section] ?? 0,
              ),
          ],
        ),
    ];
  }

  /// 회차의 검수를 시작한다: 게이트웨이가 구간마다 검수 범위(구간 문서·책 행)를 만들고, 작업 지시를 저장한 뒤
  /// 실행기에 넣는다. 아직 추출하지 않은 회차는 추출을 건다(실행기가 끝나기를 기다렸다가 이어 간다).
  ///
  /// [restart] 가 false 면 아직 검수를 시작하지 않은 구간만 넣는다. true 면(PDF 를 다시 올렸을 때) 회차를 다시
  /// 추출하고 모든 구간을 처음부터 다시 검수한다(확정도 풀린다).
  Future<MockExamReviewStartResult> startReview({
    required String academyId,
    required String examId,
    bool restart = false,
  }) async {
    final Map<String, dynamic> identity;
    try {
      identity = await _pb.prepareMockReviewIdentity(academyId: academyId, examId: examId);
    } catch (e) {
      throw Exception(describeError(e));
    }
    final title = '${identity['title'] ?? ''}'.trim();
    final sections = [
      for (final s in (identity['sections'] as List?) ?? const [])
        if (s is Map) Map<String, dynamic>.from(s),
    ];
    if (sections.isEmpty) throw Exception('검수할 구간이 없습니다. 문제지 PDF 를 확인하세요');
    final orders = [for (final s in sections) mockExamWorkOrder(academyId: academyId, title: title, section: s)];
    for (final o in orders) {
      if (o.bookId.isEmpty || o.gradeLabel.isEmpty) throw Exception('검수 과정을 정하지 못했습니다');
    }
    final existing = restart ? const <String, TextbookSubunitWorkflow>{} : await _workflows.fetchMockExams(academyId);
    final targets = [
      for (final o in orders)
        if (existing[o.bookId]?.workOrder == null) o,
    ];

    // 추출: 다시 올린 회차는 전체를 다시 뽑고, 아직 아무 구간도 뽑지 않은 회차는 처음 뽑는다.
    // 일부 구간만 뽑힌 회차는 실행기의 첫 준비 호출에서 게이트웨이가 빠진 구간만 뽑는다.
    final examStatus = '${identity['examStatus'] ?? ''}'.trim();
    final busy = examStatus == 'queued' || examStatus == 'running';
    final nothingExtracted = sections.every((s) => ((s['questionCount'] as num?)?.toInt() ?? 0) == 0);
    var requested = false;
    if (targets.isNotEmpty && !busy && (restart || nothingExtracted)) {
      await _mock.requestExtraction(examId, 'all');
      requested = true;
    }
    for (final o in targets) {
      await _workflows.confirmCrop(o);
      _runner.enqueue(o);
    }
    return MockExamReviewStartResult(
      examId: examId,
      title: title,
      grade: (identity['grade'] as num?)?.toInt() ?? 0,
      started: targets.length,
      extractionRequested: requested,
    );
  }

  /// 게이트웨이가 돌려준 구간 하나의 작업 지시. 구간 전체가 검수 범위 하나다(대·중단원 0, 작업 단위 A).
  static TextbookSubunitWorkOrder mockExamWorkOrder({
    required String academyId,
    required String title,
    required Map<String, dynamic> section,
  }) {
    final label = '${section['label'] ?? ''}'.trim();
    final bookName = '${section['bookName'] ?? ''}'.trim();
    return TextbookSubunitWorkOrder(
      academyId: academyId,
      bookId: '${section['bookId'] ?? section['documentId'] ?? ''}'.trim(),
      bookName: bookName,
      gradeLabel: '${section['gradeLabel'] ?? ''}'.trim(),
      seriesKey: TextbookSubunitWorkOrder.mockExamSeriesKey,
      bigOrder: 0,
      midOrder: 0,
      bigName: title,
      midName: label,
      scopeKey: 'A',
      label: bookName.isNotEmpty ? bookName : [title, label].where((x) => x.isNotEmpty).join(' · '),
      supportsExtraction: false,
      reviewSubKeys: const ['A'],
      indexedSubKeys: const ['A'],
    );
  }

  /// 실패했거나 멈춘 구간 검수를 그 단계부터 다시 돌린다. 이미 돌고 있으면 false.
  bool retry(MockExamReviewSection section) {
    final wf = section.workflow;
    final order = wf?.workOrder;
    if (wf == null || order == null) return false;
    return _runner.enqueue(
      order,
      fromPhase: TextbookWorkflowPhase.resumeFrom(wf.pipelinePhase),
    );
  }

  /// 앱을 닫아 진행 중으로 남은 검수를 이어 돌린다. 반환: 다시 넣은 수
  int resumeUnfinished(Iterable<MockExamReviewExam> exams) => _runner.resumeUnfinished([
        for (final e in exams) ...e.workflows,
      ]);

  /// 파일명으로 읽은 PDF 묶음을 회차별로 올리고 바로 검수를 시작한다(구간 문서를 만든 뒤 추출을 건다).
  /// 회차마다 따로 처리해, 한 회차가 실패해도 나머지는 계속한다.
  /// [activeExamIds] 는 지금 검수가 돌고 있는 회차다(돌고 있는 회차의 PDF 는 바꾸지 않는다).
  Future<({List<MockExamReviewStartResult> started, List<String> failures})> uploadAndStart({
    required String academyId,
    required List<MockExamFileName> files,
    Map<String, String> examIdByKey = const {},
    Set<String> activeExamIds = const {},
    void Function(String message)? onProgress,
  }) async {
    final byExam = <String, List<MockExamFileName>>{};
    for (final f in files) {
      byExam.putIfAbsent(f.examKey, () => <MockExamFileName>[]).add(f);
    }
    final started = <MockExamReviewStartResult>[];
    final failures = <String>[];
    var index = 0;
    for (final group in byExam.values) {
      index += 1;
      final head = group.first;
      try {
        if (activeExamIds.contains(examIdByKey[head.examKey])) {
          throw Exception('검수가 돌고 있는 회차입니다. 중단한 뒤에 다시 올리세요');
        }
        final ids = await _mock.uploadBatch(
          academyId: academyId,
          files: group,
          requestExtraction: false,
          onProgress: (m) => onProgress?.call('[$index/${byExam.length}] ${m.replaceFirst(RegExp(r'^\[\d+/\d+\]\s*'), '')}'),
        );
        onProgress?.call('[$index/${byExam.length}] ${head.title} 검수 준비');
        started.add(await startReview(academyId: academyId, examId: ids.single, restart: true));
      } catch (e) {
        failures.add('${head.title}: ${describeError(e)}');
      }
    }
    return (started: started, failures: failures);
  }

  /// 게이트웨이·추출 오류 코드를 사람이 읽을 말로 바꾼다.
  static String describeError(Object error) {
    final text = '$error';
    if (text.contains('exam_extracting')) return '회차를 추출하는 중입니다. 추출이 끝난 뒤에 검수를 시작하세요';
    if (text.contains('problem_paper_missing')) return '문제지 PDF 가 없어 검수할 수 없습니다';
    if (text.contains('exam_not_found')) return '모의고사 회차를 찾지 못했습니다';
    return TextbookWorkflowRunner.describeMockPrepareError(error);
  }
}
