import 'package:supabase_flutter/supabase_flutter.dart';

import 'learning_problem_bank_service.dart';
import 'tenant_service.dart';

/// 학생 교재 문항 신고 사유 라벨.
const Map<String, String> kTextbookReportIssueLabels = {
  'question_error': '문제 오류',
  'answer_error': '정답 오류',
  'answer_input_blocked': '정답 입력 불가',
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

/// 신고 문항의 정답 표시용 뷰.
///
/// render: 통합 정답 렌더 PNG (v11/v10)
/// image: 원본 정답 이미지
/// text: 텍스트/LaTeX 폴백
/// none: 정답 없음
class TextbookReportAnswerView {
  const TextbookReportAnswerView({
    required this.status,
    this.answerKind = '',
    this.answerText = '',
    this.renders = const <LearningProblemAnswerRender>[],
    this.imageUrl,
    this.imageWidthPx,
    this.imageHeightPx,
  });

  final String status; // render | image | text | none
  final String answerKind;
  final String answerText;
  final List<LearningProblemAnswerRender> renders;
  final String? imageUrl;
  final int? imageWidthPx;
  final int? imageHeightPx;

  bool get hasContent =>
      status == 'render' || status == 'image' || status == 'text';
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

  /// 신고 문항의 정답 뷰를 해석한다.
  ///
  /// 우선순위: 통합 정답 렌더(v11→v10) → 원본 정답 이미지 → 텍스트/LaTeX.
  /// 게이트웨이 없이 Supabase만으로 동작해 문항 뷰와 같은 경로를 쓴다.
  Future<TextbookReportAnswerView> resolveAnswerView(
    StudentTextbookReport report,
  ) async {
    final cropId = report.cropId.trim();
    if (cropId.isEmpty) {
      return const TextbookReportAnswerView(status: 'none');
    }

    final answerRow = await _client
        .from('textbook_problem_answers')
        .select(
          'answer_kind, answer_text, answer_latex_2d, '
          'answer_image_bucket, answer_image_path, '
          'answer_image_width_px, answer_image_height_px',
        )
        .eq('academy_id', report.academyId)
        .eq('crop_id', cropId)
        .maybeSingle();

    final answerKind =
        '${answerRow?['answer_kind'] ?? ''}'.trim().toLowerCase();
    final answerText = _answerTextFromRow(answerRow);
    final preferredKind =
        answerKind == 'objective' ? 'objective' : 'subjective';
    final fallbackKind =
        preferredKind == 'objective' ? 'subjective' : 'objective';

    var usedKind = preferredKind;
    var renders = await _loadAnswerRenders(
      academyId: report.academyId,
      cropId: cropId,
      answerKind: preferredKind,
    );
    if (renders.isEmpty) {
      renders = await _loadAnswerRenders(
        academyId: report.academyId,
        cropId: cropId,
        answerKind: fallbackKind,
      );
      if (renders.isNotEmpty) usedKind = fallbackKind;
    }
    if (renders.isNotEmpty) {
      return TextbookReportAnswerView(
        status: 'render',
        answerKind: usedKind,
        answerText: answerText,
        renders: renders,
      );
    }

    // 객관식 텍스트는 렌더 없이도 바로 판독 가능.
    if (preferredKind == 'objective' && answerText.isNotEmpty) {
      return TextbookReportAnswerView(
        status: 'text',
        answerKind: preferredKind,
        answerText: answerText,
      );
    }

    final imageBucket =
        '${answerRow?['answer_image_bucket'] ?? ''}'.trim();
    final imagePath = '${answerRow?['answer_image_path'] ?? ''}'.trim();
    if (imageBucket.isNotEmpty && imagePath.isNotEmpty) {
      try {
        final url = await _client.storage
            .from(imageBucket)
            .createSignedUrl(imagePath, _signedUrlSeconds);
        return TextbookReportAnswerView(
          status: 'image',
          answerKind: answerKind.isEmpty ? 'image' : answerKind,
          answerText: answerText,
          imageUrl: url,
          imageWidthPx: _asInt(answerRow?['answer_image_width_px']),
          imageHeightPx: _asInt(answerRow?['answer_image_height_px']),
        );
      } catch (_) {
        // 텍스트 폴백
      }
    }

    if (answerText.isNotEmpty) {
      return TextbookReportAnswerView(
        status: 'text',
        answerKind: preferredKind,
        answerText: answerText,
      );
    }
    return const TextbookReportAnswerView(status: 'none');
  }

  String _answerTextFromRow(Map<String, dynamic>? row) {
    if (row == null) return '';
    final kind = '${row['answer_kind'] ?? ''}'.trim().toLowerCase();
    final latex = '${row['answer_latex_2d'] ?? ''}'.trim();
    final text = '${row['answer_text'] ?? ''}'.trim();
    if (kind == 'subjective' && latex.isNotEmpty) return latex;
    if (text.isNotEmpty) return text;
    return latex;
  }

  Future<List<LearningProblemAnswerRender>> _loadAnswerRenders({
    required String academyId,
    required String cropId,
    required String answerKind,
  }) async {
    final styleVersions = <String>[
      kUnifiedAnswerRenderStyleVersionV11,
      kUnifiedAnswerRenderStyleVersion,
    ];
    final answerKindCandidates = <String>[
      answerKind,
      for (var p = 1; p <= 12; p++) '$answerKind#($p)',
    ];
    try {
      final rows = await _client
          .from('answer_render_assets')
          .select(
            'source_id,answer_kind,storage_bucket,storage_path,'
            'width_px,height_px,pixel_ratio,style_version,render_error,'
            'transparent',
          )
          .eq('academy_id', academyId)
          .eq('source_kind', 'textbook_crop')
          .eq('engine', 'xelatex')
          .eq('render_error', '')
          .eq('source_id', cropId)
          .inFilter('answer_kind', answerKindCandidates)
          .inFilter('style_version', styleVersions);
      final styleRank = <String, int>{
        for (var i = 0; i < styleVersions.length; i++) styleVersions[i]: i,
      };
      final bestRows = <String, Map<String, dynamic>>{};
      for (final raw in rows as List<dynamic>) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final style = '${row['style_version'] ?? ''}'.trim();
        final kind = '${row['answer_kind'] ?? ''}'.trim();
        if (style.isEmpty) continue;
        final partKey =
            kind.contains('#') ? kind.substring(kind.indexOf('#') + 1) : '';
        final entryKey = partKey.isEmpty ? cropId : '$cropId#$partKey';
        final previous = bestRows[entryKey];
        final previousStyle = '${previous?['style_version'] ?? ''}'.trim();
        if (previous == null ||
            (styleRank[style] ?? 999) < (styleRank[previousStyle] ?? 999)) {
          bestRows[entryKey] = row;
        }
      }
      if (bestRows.isEmpty) return const <LearningProblemAnswerRender>[];

      final pathsByBucket = <String, Set<String>>{};
      for (final row in bestRows.values) {
        final bucket = '${row['storage_bucket'] ?? ''}'.trim();
        final path = '${row['storage_path'] ?? ''}'.trim();
        if (bucket.isEmpty || path.isEmpty) continue;
        pathsByBucket.putIfAbsent(bucket, () => <String>{}).add(path);
      }
      final signedByKey = <String, String>{};
      await Future.wait(pathsByBucket.entries.map((entry) async {
        try {
          final signed = await _client.storage.from(entry.key).createSignedUrls(
                entry.value.toList(growable: false),
                _signedUrlSeconds,
              );
          for (final item in signed) {
            final path = item.path.trim();
            if (path.isEmpty || item.signedUrl.trim().isEmpty) continue;
            signedByKey['${entry.key}\n$path'] = item.signedUrl.trim();
          }
        } catch (_) {}
      }));

      final out = <LearningProblemAnswerRender>[];
      final orderedKeys = bestRows.keys.toList(growable: false)
        ..sort((a, b) {
          final aPart = _partOrder(a);
          final bPart = _partOrder(b);
          if (aPart != bPart) return aPart.compareTo(bPart);
          return a.compareTo(b);
        });
      for (final key in orderedKeys) {
        final row = bestRows[key]!;
        final bucket = '${row['storage_bucket'] ?? ''}'.trim();
        final path = '${row['storage_path'] ?? ''}'.trim();
        final url = signedByKey['$bucket\n$path'] ?? '';
        if (url.isEmpty) continue;
        final width = _asInt(row['width_px']) ?? 0;
        final height = _asInt(row['height_px']) ?? 0;
        final ratioRaw = (row['pixel_ratio'] as num?)?.toDouble() ?? 0;
        final ratio = ratioRaw <= 0 ? 7.0 : ratioRaw;
        final displayWidth = width > 0 ? width / ratio : 48.0;
        final displayHeight = height > 0 ? height / ratio : 38.0;
        final style = '${row['style_version'] ?? ''}'.trim();
        out.add(
          LearningProblemAnswerRender(
            key: key,
            url: url,
            width: width,
            height: height,
            pixelRatio: ratio,
            cached: true,
            error: '',
            styleVersion: style,
            displayWidthDp: displayWidth,
            displayHeightDp: displayHeight,
            transparent: row['transparent'] == true,
          ),
        );
      }
      return out;
    } catch (_) {
      return const <LearningProblemAnswerRender>[];
    }
  }

  int _partOrder(String key) {
    final hashIdx = key.indexOf('#');
    if (hashIdx < 0) return 0;
    final marker = key.substring(hashIdx + 1);
    final digits = RegExp(r'\((\d+)\)').firstMatch(marker)?.group(1);
    if (digits == null) return 999;
    return int.tryParse(digits) ?? 999;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
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
