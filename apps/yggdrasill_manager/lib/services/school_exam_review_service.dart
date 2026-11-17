import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'problem_bank_service.dart';
import 'school_exam_file_info.dart';
import 'textbook_problem_review_service.dart';
import 'textbook_workflow_runner.dart';
import 'textbook_workflow_service.dart';

/// 내신 시험지의 검수 진행 상태(교재 메뉴 목록 표시용)
enum SchoolExamStage {
  /// 시험지 PDF 가 없어 검수할 수 없다.
  noPdf,

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

/// 내신 시험지 한 부(문제은행 문서)와 검수 작업 상태. 검수의 책 id 는 문서 id 와 같다.
class SchoolExamDocument {
  const SchoolExamDocument({
    required this.id,
    required this.academyId,
    required this.status,
    required this.sourceFilename,
    required this.hasPdf,
    required this.hasHwpx,
    required this.published,
    required this.schoolName,
    required this.schoolLevel,
    required this.gradeKey,
    required this.courseKey,
    required this.courseLabel,
    required this.semesterLabel,
    required this.examTermLabel,
    this.examYear,
    this.workflow,
  });

  factory SchoolExamDocument.fromRow(Map<String, dynamic> m, {TextbookSubunitWorkflow? workflow}) {
    String text(String key) => '${m[key] ?? ''}'.trim();
    return SchoolExamDocument(
      id: text('id'),
      academyId: text('academy_id'),
      status: text('status'),
      sourceFilename: text('source_filename'),
      hasPdf: text('source_pdf_storage_path').isNotEmpty,
      hasHwpx: text('source_storage_path').isNotEmpty,
      published: text('source_type_code') == 'school_past',
      schoolName: text('school_name'),
      schoolLevel: text('school_level'),
      gradeKey: text('grade_key'),
      courseKey: text('course_key'),
      courseLabel: text('course_label'),
      semesterLabel: text('semester_label'),
      examTermLabel: text('exam_term_label'),
      examYear: int.tryParse(text('exam_year')),
      workflow: workflow,
    );
  }

  final String id;
  final String academyId;

  /// pb_documents.status
  final String status;
  final String sourceFilename;
  final bool hasPdf;
  final bool hasHwpx;

  /// 학습앱에 공개된 시험지(분류가 확정됨). 교재 메뉴에서 올린 초안은 검수 확정 때 공개된다.
  final bool published;
  final String schoolName;
  final String schoolLevel;
  final String gradeKey;
  final String courseKey;
  final String courseLabel;
  final String semesterLabel;
  final String examTermLabel;
  final int? examYear;
  final TextbookSubunitWorkflow? workflow;

  bool get isHigh => schoolLevel == 'high' || gradeKey.startsWith('H');
  int? get grade => int.tryParse(RegExp(r'([1-3])$').firstMatch(gradeKey)?.group(1) ?? '');
  bool get essayPart => sourceFilename.contains('서술형');

  /// 학교 이름을 뺀 시험지 이름: "2025 2학년 1학기 중간"(고등은 과정 이름을 붙인다). 게이트웨이와 같은 규칙.
  String get title {
    final parts = [
      if (examYear != null) '$examYear',
      if (grade != null) '$grade학년',
      if (semesterLabel.isNotEmpty) semesterLabel,
      if (examTermLabel.isNotEmpty) examTermLabel,
      if (isHigh && courseLabel.isNotEmpty) courseLabel,
      if (essayPart) '(서술형)',
    ];
    return parts.isEmpty ? (sourceFilename.isEmpty ? '시험지' : sourceFilename) : parts.join(' ');
  }

  /// 같은 시험지를 가리는 키
  String get examKey => schoolExamKey(
        schoolName: schoolName,
        examYear: examYear,
        gradeKey: gradeKey,
        semesterLabel: semesterLabel,
        examTermLabel: examTermLabel,
        courseKey: courseKey,
        essayPart: essayPart,
      );

  SchoolExamStage get stage {
    final wf = workflow;
    if (wf != null && wf.isConfirmed) return SchoolExamStage.confirmed;
    if (wf == null || wf.workOrder == null) return hasPdf ? SchoolExamStage.notStarted : SchoolExamStage.noPdf;
    return switch (wf.pipelineStatus) {
      'queued' || 'running' => SchoolExamStage.running,
      'failed' => SchoolExamStage.failed,
      'done' => SchoolExamStage.reviewing,
      _ => SchoolExamStage.stopped,
    };
  }

  /// 목록 정렬: 최근 연도 → 학년 → 학기 → 중간·기말 → 과정
  static int compare(SchoolExamDocument a, SchoolExamDocument b) {
    var c = (b.examYear ?? 0).compareTo(a.examYear ?? 0);
    if (c != 0) return c;
    c = (a.grade ?? 9).compareTo(b.grade ?? 9);
    if (c != 0) return c;
    c = a.semesterLabel.compareTo(b.semesterLabel);
    if (c != 0) return c;
    c = (a.examTermLabel == '기말' ? 1 : 0).compareTo(b.examTermLabel == '기말' ? 1 : 0);
    if (c != 0) return c;
    c = a.courseLabel.compareTo(b.courseLabel);
    return c != 0 ? c : a.sourceFilename.compareTo(b.sourceFilename);
  }
}

String schoolExamKey({
  required String schoolName,
  required int? examYear,
  required String gradeKey,
  required String semesterLabel,
  required String examTermLabel,
  required String courseKey,
  required bool essayPart,
}) =>
    [schoolName, examYear ?? '', gradeKey, semesterLabel, examTermLabel, courseKey, essayPart ? 'essay' : ''].join('|');

/// 학교 하나의 시험지 묶음
class SchoolExamSchool {
  const SchoolExamSchool({required this.name, required this.isHigh, required this.exams});

  final String name;
  final bool isHigh;
  final List<SchoolExamDocument> exams;

  int get confirmedCount => exams.where((e) => e.stage == SchoolExamStage.confirmed).length;
}

/// 올릴 시험지 한 부(업로드 창에서 온다)
class SchoolExamUpload {
  const SchoolExamUpload({
    required this.info,
    required this.pdfName,
    required this.pdfBytes,
    this.hwpxName = '',
    this.hwpxBytes,
  });

  final SchoolExamFileInfo info;
  final String pdfName;
  final Uint8List pdfBytes;
  final String hwpxName;
  final Uint8List? hwpxBytes;
}

/// 교재 메뉴의 내신기출: 학교별 시험지 목록, 업로드(추출 시작), 검수 시작.
/// 검수는 시중교재와 같은 실행기([TextbookWorkflowRunner])와 작업 화면을 쓴다.
class SchoolExamReviewService {
  SchoolExamReviewService({SupabaseClient? client, ProblemBankService? problemBank})
      : _db = client ?? Supabase.instance.client,
        _pb = problemBank ?? ProblemBankService();

  final SupabaseClient _db;
  final ProblemBankService _pb;
  final TextbookWorkflowService _workflows = TextbookWorkflowService();

  static const _columns = 'id,academy_id,status,source_filename,source_storage_path,source_pdf_storage_path,'
      'source_type_code,school_level,grade_key,course_key,course_label,exam_year,semester_label,exam_term_label,'
      'school_name';

  Future<String> resolveAcademyId() => _pb.resolveAcademyId();

  Future<List<Map<String, dynamic>>> _documentRows(String academyId, {required bool drafts}) async {
    const pageSize = 1000;
    final out = <Map<String, dynamic>>[];
    for (var from = 0;; from += pageSize) {
      final base = _db.from('pb_documents').select(_columns).eq('academy_id', academyId);
      // 공개된 내신 시험지, 그리고 교재 메뉴에서 올려 아직 공개 전인 초안(분류 코드가 비어 있다).
      final filtered = drafts
          ? base.eq('source_type_code', '').not('meta->exam_review', 'is', null)
          : base.eq('source_type_code', 'school_past');
      final page = await filtered.order('id', ascending: true).range(from, from + pageSize - 1);
      final rows = [for (final r in (page as List).whereType<Map>()) Map<String, dynamic>.from(r)];
      out.addAll(rows);
      if (rows.length < pageSize) break;
    }
    return out;
  }

  /// 학교별 시험지 목록. 중학교 다음 고등학교, 학교 이름 순.
  Future<List<SchoolExamSchool>> fetchSchools(String academyId) async {
    final results = await Future.wait([
      _documentRows(academyId, drafts: false),
      _documentRows(academyId, drafts: true),
    ]);
    final workflows = await _workflows.fetchSchoolExams(academyId);
    final byId = <String, SchoolExamDocument>{};
    for (final row in [...results[0], ...results[1]]) {
      final id = '${row['id'] ?? ''}';
      if (id.isEmpty) continue;
      byId[id] = SchoolExamDocument.fromRow(row, workflow: workflows[id]);
    }
    final bySchool = <String, List<SchoolExamDocument>>{};
    for (final doc in byId.values) {
      bySchool.putIfAbsent(doc.schoolName.isEmpty ? '학교 미지정' : doc.schoolName, () => []).add(doc);
    }
    final schools = [
      for (final e in bySchool.entries)
        SchoolExamSchool(
          name: e.key,
          isHigh: e.value.any((d) => d.isHigh),
          exams: e.value..sort(SchoolExamDocument.compare),
        ),
    ]..sort((a, b) {
        if (a.isHigh != b.isHigh) return a.isHigh ? 1 : -1;
        return a.name.compareTo(b.name);
      });
    return schools;
  }

  /// 검수를 시작한다: 게이트웨이가 책 행과 시험지 PDF 연결을 만들고, 작업 지시를 저장한 뒤 실행기에 넣는다.
  /// 이미 공개된 시험지는 정답만 검수하고, 새로 올린 시험지는 그림 크기·위치까지 전체 검수한다.
  Future<TextbookSubunitWorkOrder> startReview({
    required String academyId,
    required String documentId,
    required bool published,
  }) async {
    final Map<String, dynamic> identity;
    try {
      identity = await _pb.prepareExamReview(academyId: academyId, documentId: documentId, identityOnly: true);
    } catch (e) {
      throw Exception(describeError(e));
    }
    final title = '${identity['title'] ?? ''}'.trim();
    final order = TextbookSubunitWorkOrder(
      academyId: academyId,
      bookId: '${identity['bookId'] ?? documentId}',
      bookName: '${identity['bookName'] ?? ''}'.trim(),
      gradeLabel: '${identity['gradeLabel'] ?? ''}'.trim(),
      seriesKey: TextbookSubunitWorkOrder.schoolExamSeriesKey,
      bigOrder: 0,
      midOrder: 0,
      bigName: '${identity['schoolName'] ?? ''}'.trim(),
      midName: title,
      scopeKey: 'A',
      label: title.isEmpty ? '시험지' : title,
      supportsExtraction: false,
      reviewSubKeys: const ['A'],
      indexedSubKeys: const ['A'],
      reviewMode: published ? TextbookReviewUnitScope.answerOnlyMode : '',
    );
    if (order.gradeLabel.isEmpty) throw Exception('검수 과정을 정하지 못했습니다');
    await _workflows.confirmCrop(order);
    TextbookWorkflowRunner.instance.enqueue(order);
    return order;
  }

  /// 실패했거나 멈춘 검수를 그 단계부터 다시 돌린다. 이미 돌고 있으면 false.
  bool retry(SchoolExamDocument doc) {
    final wf = doc.workflow;
    final order = wf?.workOrder;
    if (wf == null || order == null) return false;
    return TextbookWorkflowRunner.instance.enqueue(
      order,
      fromPhase: TextbookWorkflowPhase.resumeFrom(wf.pipelinePhase),
    );
  }

  /// 앱을 닫아 진행 중으로 남은 검수를 이어 돌린다. 반환: 다시 넣은 수
  int resumeUnfinished(Iterable<SchoolExamSchool> schools) => TextbookWorkflowRunner.instance.resumeUnfinished([
        for (final s in schools)
          for (final e in s.exams)
            if (e.workflow != null) e.workflow!,
      ]);

  /// 시험지를 올려 초안 문서를 만들고 본문 추출을 건 뒤 바로 검수 대기열에 넣는다.
  /// 초안은 만들었는데 추출·검수 예약에 실패하면 warning 에 이유를 담는다(목록에서 "검수 시작"으로 잇는다).
  Future<({String documentId, String warning})> uploadAndStart({
    required String academyId,
    required SchoolExamUpload upload,
  }) async {
    final info = upload.info;
    final documentId = await _pb.createExamReviewDraft(
      academyId: academyId,
      pdfBytes: upload.pdfBytes,
      pdfName: upload.pdfName,
      hwpxBytes: upload.hwpxBytes,
      hwpxName: upload.hwpxName,
      labelColumns: info.classificationColumns(),
      examReview: <String, dynamic>{
        'curriculum_code': info.curriculumCode,
        'essay_part': info.essayPart,
        'uploaded_from': 'textbook_menu',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      sourceClassification: info.sourceClassification(),
    );
    try {
      // 추출은 서버 워커가 차례로 돈다. 검수 실행기는 추출이 끝나기를 기다렸다가 이어 간다.
      await _pb.createExtractJob(academyId: academyId, documentId: documentId);
      await startReview(academyId: academyId, documentId: documentId, published: false);
      return (documentId: documentId, warning: '');
    } catch (e) {
      return (documentId: documentId, warning: describeError(e));
    }
  }

  /// 아직 공개하지 않은 초안 시험지를 지운다(문서·문항·원본 파일·검수 기록).
  Future<void> deleteDraft(SchoolExamDocument doc) async {
    if (doc.published) throw Exception('공개된 시험지는 문제은행에서 관리합니다');
    final key = doc.workflow?.key;
    if (key != null) TextbookWorkflowRunner.instance.cancel(key);
    await _pb.deleteExamReviewDraft(academyId: doc.academyId, documentId: doc.id);
  }

  /// 게이트웨이·추출 오류 코드를 사람이 읽을 말로 바꾼다.
  static String describeError(Object error) {
    final text = '$error';
    if (text.contains('pdf_source_required')) return '시험지 PDF 가 없어 검수할 수 없습니다';
    if (text.contains('course_unresolved')) return '시험지의 과정(과목)을 알 수 없어 검수 범위를 정하지 못했습니다';
    if (text.contains('not_school_exam')) return '내신 시험지 문서가 아닙니다';
    if (text.contains('document_not_found')) return '문제은행에서 시험지 문서를 찾지 못했습니다';
    if (text.contains('no_questions')) return '추출된 문항이 없습니다';
    return text.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }
}
