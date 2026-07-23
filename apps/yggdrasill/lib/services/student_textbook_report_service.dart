import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

/// 학생 교재 문항 신고 사유 라벨.
const Map<String, String> kTextbookReportIssueLabels = {
  'question_error': '문제 오류',
  'answer_error': '정답 오류',
  'render_error': '렌더/그림 오류',
  'other': '기타',
};

/// 반려 시 후속 처리 라벨.
const Map<String, String> kTextbookReportResolutionLabels = {
  'regrade': '저장된 답 채점',
  'redo': '재풀이 요청',
  'waive': '면제',
};

class StudentTextbookReport {
  const StudentTextbookReport({
    required this.id,
    required this.academyId,
    required this.studentId,
    required this.studentName,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.cropId,
    required this.problemNumber,
    this.rawPage,
    this.displayPage,
    this.itemRegion1k,
    this.pbQuestionUid,
    required this.issueTypes,
    required this.note,
    required this.status,
    this.resolution,
    required this.resolutionNote,
    this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String academyId;
  final String studentId;
  final String studentName;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final String cropId;
  final String problemNumber;
  final int? rawPage;
  final int? displayPage;
  final List<int>? itemRegion1k;
  final String? pbQuestionUid;
  final List<String> issueTypes;
  final String note;

  /// open(검토 중) | accepted(신고 인정) | rejected(반려)
  final String status;

  /// rejected일 때: regrade | redo | waive
  final String? resolution;
  final String resolutionNote;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  bool get isOpen => status == 'open';
  int get shownPage => displayPage ?? rawPage ?? 0;

  static StudentTextbookReport fromRow(Map<String, dynamic> row) {
    final student = row['students'] is Map
        ? Map<String, dynamic>.from(row['students'] as Map)
        : const <String, dynamic>{};
    final crop = row['textbook_problem_crops'] is Map
        ? Map<String, dynamic>.from(row['textbook_problem_crops'] as Map)
        : const <String, dynamic>{};
    final book = row['resource_files'] is Map
        ? Map<String, dynamic>.from(row['resource_files'] as Map)
        : const <String, dynamic>{};
    final rawRegion = crop['item_region_1k'];
    final region = rawRegion is List
        ? rawRegion
            .whereType<num>()
            .map((v) => v.toInt())
            .toList(growable: false)
        : null;
    return StudentTextbookReport(
      id: '${row['id']}',
      academyId: '${row['academy_id']}',
      studentId: '${row['student_id']}',
      studentName: (student['name'] as String?)?.trim() ?? '학생',
      bookId: '${row['book_id']}',
      bookName: (book['name'] as String?)?.trim() ?? '교재',
      gradeLabel: (row['grade_label'] as String?) ?? '',
      cropId: '${row['crop_id']}',
      problemNumber: (crop['problem_number'] as String?) ?? '',
      rawPage: (crop['raw_page'] as num?)?.toInt(),
      displayPage: (crop['display_page'] as num?)?.toInt(),
      itemRegion1k: region?.length == 4 ? region : null,
      pbQuestionUid: (crop['pb_question_uid'] as String?)?.trim(),
      issueTypes:
          (row['issue_types'] as List<dynamic>?)?.cast<String>() ?? const [],
      note: (row['note'] as String?) ?? '',
      status: (row['status'] as String?) ?? 'open',
      resolution: row['resolution'] as String?,
      resolutionNote: (row['resolution_note'] as String?) ?? '',
      createdAt: row['created_at'] != null
          ? DateTime.tryParse('${row['created_at']}')?.toLocal()
          : null,
      resolvedAt: row['resolved_at'] != null
          ? DateTime.tryParse('${row['resolved_at']}')?.toLocal()
          : null,
    );
  }
}

/// 신고 문항을 학생 화면과 동일하게 보여주기 위한 뷰 정보.
///
/// ready: 워커가 렌더한 단일 문항 PDF (학생 앱과 동일 산출물)
/// fallback: 원본 교재 body PDF + crop 영역
class TextbookReportQuestionView {
  const TextbookReportQuestionView({
    required this.status,
    this.pdfUrl,
    this.bodyPdfUrl,
    this.rawPage,
    this.itemRegion1k,
  });

  final String status; // ready | fallback | none
  final String? pdfUrl;
  final String? bodyPdfUrl;
  final int? rawPage;
  final List<int>? itemRegion1k;

  bool get isReady => status == 'ready';
  bool get isFallback => status == 'fallback';
}

/// 학생 교재 문항 신고 조회·판정 (학습앱 스태프용).
class StudentTextbookReportService {
  StudentTextbookReportService._();

  static final StudentTextbookReportService instance =
      StudentTextbookReportService._();

  // 학생 앱 렌더 산출물과 동일 프로필 (student_textbook_problem_view Edge와 동일).
  static const String _renderProfile = 'student-single-v1';
  static const String _rendererVersion =
      'pb_render_v4_slotmeasure_01:student-single-v4';
  static const int _signedUrlSeconds = 600;

  SupabaseClient get _client => Supabase.instance.client;

  Future<String> _academyId() async {
    final id = (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (id.isNotEmpty) return id;
    return (await TenantService.instance.ensureActiveAcademy()).trim();
  }

  /// 검토 중(open) 신고 건수 — 홈 배지용.
  Future<int> openReportCount() async {
    final academyId = await _academyId();
    if (academyId.isEmpty) return 0;
    final rows = await _client
        .from('student_textbook_problem_reports')
        .select('id')
        .eq('academy_id', academyId)
        .eq('status', 'open') as List<dynamic>;
    return rows.length;
  }

  /// 신고 목록 (학생·교재·문항 정보 포함). open이 먼저, 최신순.
  Future<List<StudentTextbookReport>> listReports({
    bool includeResolved = true,
  }) async {
    final academyId = await _academyId();
    if (academyId.isEmpty) return const [];
    var query = _client
        .from('student_textbook_problem_reports')
        .select('*, students(name), resource_files(name), '
            'textbook_problem_crops(problem_number, raw_page, display_page, '
            'item_region_1k, pb_question_uid)')
        .eq('academy_id', academyId);
    if (!includeResolved) {
      query = query.eq('status', 'open');
    }
    final rows =
        await query.order('created_at', ascending: false) as List<dynamic>;
    final reports = rows
        .whereType<Map<String, dynamic>>()
        .map(StudentTextbookReport.fromRow)
        .toList(growable: false);
    // 검토 중 우선 정렬
    return [
      ...reports.where((r) => r.isOpen),
      ...reports.where((r) => !r.isOpen),
    ];
  }

  /// 신고 문항의 학생 화면과 동일한 렌더 뷰를 해석한다.
  ///
  /// 학생 Edge Function과 같은 우선순위: question_render_assets(단일 문항 PDF)
  /// → 원본 교재 body PDF crop. content_hash 검증은 완화(최신 정상 산출물 사용).
  Future<TextbookReportQuestionView> resolveQuestionView(
    StudentTextbookReport report,
  ) async {
    final asset = await _client
        .from('question_render_assets')
        .select('storage_bucket, storage_path')
        .eq('academy_id', report.academyId)
        .eq('crop_id', report.cropId)
        .eq('render_profile', _renderProfile)
        .eq('renderer_version', _rendererVersion)
        .eq('render_error', '')
        .not('rendered_at', 'is', null)
        .order('rendered_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (asset != null) {
      final bucket = '${asset['storage_bucket']}';
      final path = '${asset['storage_path']}';
      if (bucket.isNotEmpty && path.isNotEmpty) {
        try {
          final url = await _client.storage
              .from(bucket)
              .createSignedUrl(path, _signedUrlSeconds);
          return TextbookReportQuestionView(status: 'ready', pdfUrl: url);
        } catch (_) {
          // 서명 실패 시 body fallback으로 진행
        }
      }
    }

    final link = await _client
        .from('resource_file_links')
        .select('storage_bucket, storage_key')
        .eq('academy_id', report.academyId)
        .eq('file_id', report.bookId)
        .eq('grade', '${report.gradeLabel}#body')
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (link != null) {
      final bucket = '${link['storage_bucket']}';
      final key = '${link['storage_key']}';
      if (bucket.isNotEmpty && key.isNotEmpty) {
        try {
          final url = await _client.storage
              .from(bucket)
              .createSignedUrl(key, _signedUrlSeconds);
          return TextbookReportQuestionView(
            status: 'fallback',
            bodyPdfUrl: url,
            rawPage: report.rawPage,
            itemRegion1k: report.itemRegion1k,
          );
        } catch (_) {
          // 아래 none으로
        }
      }
    }
    return const TextbookReportQuestionView(status: 'none');
  }

  /// 신고 판정.
  ///
  /// accepted: 신고 인정 — 문항은 계속 통계 제외(무효 처리).
  /// rejected: 반려 — [resolution]으로 후속 처리 기록
  ///   (regrade: 저장된 답 채점 / redo: 재풀이 요청 / waive: 면제).
  Future<void> resolveReport({
    required String reportId,
    required String status,
    String? resolution,
    String resolutionNote = '',
  }) async {
    assert(status == 'accepted' || status == 'rejected');
    await _client.from('student_textbook_problem_reports').update({
      'status': status,
      'resolution': status == 'rejected' ? resolution : null,
      'resolution_note': resolutionNote.trim(),
      'resolved_by': _client.auth.currentUser?.id,
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', reportId);
  }
}
