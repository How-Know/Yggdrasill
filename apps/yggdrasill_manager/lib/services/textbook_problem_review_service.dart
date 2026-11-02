import 'package:supabase_flutter/supabase_flutter.dart';

import 'problem_bank_service.dart';

class TextbookReviewUnitScope {
  const TextbookReviewUnitScope({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.bigOrder,
    required this.midOrder,
    required this.bigName,
    required this.midName,
    required this.problemCount,
    required this.analyzedCount,
    required this.mathCleanCount,
    required this.mathIssueCount,
    required this.mathApprovedCount,
    required this.qualityCleanCount,
    required this.qualityIssueCount,
    required this.qualityApprovedCount,
  });

  factory TextbookReviewUnitScope.fromJson(Map<String, dynamic> m) => TextbookReviewUnitScope(
        academyId: '${m['academy_id'] ?? ''}',
        bookId: '${m['book_id'] ?? ''}',
        bookName: '${m['book_name'] ?? ''}',
        gradeLabel: '${m['grade_label'] ?? ''}',
        bigOrder: (m['big_order'] as num?)?.toInt() ?? 1,
        midOrder: (m['mid_order'] as num?)?.toInt() ?? 1,
        bigName: '${m['big_name'] ?? ''}',
        midName: '${m['mid_name'] ?? ''}',
        problemCount: (m['problem_count'] as num?)?.toInt() ?? 0,
        analyzedCount: (m['analyzed_count'] as num?)?.toInt() ?? 0,
        mathCleanCount: (m['math_clean_count'] as num?)?.toInt() ?? 0,
        mathIssueCount: (m['math_issue_count'] as num?)?.toInt() ?? 0,
        mathApprovedCount: (m['math_approved_count'] as num?)?.toInt() ?? 0,
        qualityCleanCount: (m['quality_clean_count'] as num?)?.toInt() ?? 0,
        qualityIssueCount: (m['quality_issue_count'] as num?)?.toInt() ?? 0,
        qualityApprovedCount: (m['quality_approved_count'] as num?)?.toInt() ?? 0,
      );

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int bigOrder;
  final int midOrder;
  final String bigName;
  final String midName;
  final int problemCount;
  final int analyzedCount;
  final int mathCleanCount;
  final int mathIssueCount;
  final int mathApprovedCount;
  final int qualityCleanCount;
  final int qualityIssueCount;
  final int qualityApprovedCount;

  String get key => '$academyId|$bookId|$gradeLabel|$bigOrder|$midOrder';
  String get bookTitle => '$bookName ($gradeLabel)';
  String get unitTitle => '$bigOrder. $bigName › $midOrder. $midName ($problemCount문항)';
}

class TextbookProblemReviewItem {
  const TextbookProblemReviewItem({
    required this.cropId,
    required this.pbQuestionId,
    required this.questionUid,
    required this.documentId,
    required this.subKey,
    required this.subIndex,
    required this.itemName,
    required this.problemNumber,
    required this.label,
    required this.rawPage,
    required this.displayPage,
    required this.storageBucket,
    required this.storageKey,
    required this.answerKind,
    required this.existingAnswer,
    required this.answerManual,
    required this.hasSolutionRef,
    required this.solutionRawPage,
    required this.stem,
    required this.commonStem,
    required this.setType,
    required this.setHeaderNumber,
    required this.questionType,
    required this.choices,
    required this.solutionTranscribed,
    required this.solutionAnswer,
    required this.aiSolution,
    required this.aiAnswer,
    required this.matchMode,
    required this.answerMatched,
    required this.mismatchReason,
    required this.conceptScore,
    required this.thinkingScore,
    required this.arithmeticScore,
    required this.totalDifficulty,
    required this.visualTags,
    required this.qualityChecks,
    required this.draftProposals,
    required this.mathStatus,
    required this.qualityStatus,
    required this.concepts,
    required this.thinkings,
    required this.arithmetics,
    required this.findings,
  });

  factory TextbookProblemReviewItem.fromJson(Map<String, dynamic> m) {
    List<Map<String, dynamic>> mapList(Object? v) => [
          for (final x in (v as List?) ?? const [])
            if (x is Map) Map<String, dynamic>.from(x),
        ];
    return TextbookProblemReviewItem(
      cropId: '${m['crop_id'] ?? ''}',
      pbQuestionId: '${m['pb_question_id'] ?? ''}'.trim(),
      questionUid: '${m['question_uid'] ?? ''}'.trim(),
      documentId: '${m['document_id'] ?? ''}'.trim(),
      subKey: '${m['sub_key'] ?? ''}',
      subIndex: (m['sub_index'] as num?)?.toInt() ?? 0,
      itemName: '${m['item_name'] ?? ''}',
      problemNumber: '${m['problem_number'] ?? ''}',
      label: '${m['label'] ?? ''}',
      rawPage: (m['raw_page'] as num?)?.toInt() ?? 0,
      displayPage: (m['display_page'] as num?)?.toInt(),
      storageBucket: '${m['storage_bucket'] ?? 'textbook-crops'}',
      storageKey: '${m['storage_key'] ?? ''}',
      answerKind: '${m['answer_kind'] ?? ''}',
      existingAnswer: '${m['existing_answer'] ?? ''}',
      answerManual: m['answer_manual'] == true,
      hasSolutionRef: m['has_solution_ref'] == true,
      solutionRawPage: (m['solution_raw_page'] as num?)?.toInt(),
      stem: '${m['stem'] ?? ''}',
      commonStem: '${m['common_stem'] ?? ''}'.trim(),
      setType: '${m['set_type'] ?? ''}'.trim(),
      setHeaderNumber: '${m['set_header_number'] ?? ''}'.trim(),
      questionType: '${m['question_type'] ?? ''}',
      choices: [for (final x in (m['choices'] as List?) ?? const []) '$x'],
      solutionTranscribed: m['solution_transcribed'] is String ? '${m['solution_transcribed']}' : null,
      solutionAnswer: m['solution_answer'] is String ? '${m['solution_answer']}' : null,
      aiSolution: m['ai_solution'] is String ? '${m['ai_solution']}' : null,
      aiAnswer: m['ai_answer'] is String ? '${m['ai_answer']}' : null,
      matchMode: '${m['match_mode'] ?? '2way'}',
      answerMatched: m['answer_matched'] is bool ? m['answer_matched'] as bool : null,
      mismatchReason: m['mismatch_reason'] is String ? '${m['mismatch_reason']}' : null,
      conceptScore: (m['concept_score'] as num?)?.toDouble() ?? 0.0,
      thinkingScore: (m['thinking_score'] as num?)?.toDouble() ?? 0.0,
      arithmeticScore: (m['arithmetic_score'] as num?)?.toDouble() ?? 0.0,
      totalDifficulty: (m['total_difficulty'] as num?)?.toDouble() ?? 0.0,
      visualTags: [for (final x in (m['visual_tags'] as List?) ?? const []) '$x'],
      qualityChecks: m['quality_checks'] is Map
          ? Map<String, dynamic>.from(m['quality_checks'] as Map)
          : const <String, dynamic>{},
      draftProposals: mapList(m['draft_proposals']),
      mathStatus: '${m['math_status'] ?? 'pending'}',
      qualityStatus: '${m['quality_status'] ?? 'pending'}',
      concepts: mapList(m['concepts']),
      thinkings: mapList(m['thinkings']),
      arithmetics: mapList(m['arithmetics']),
      findings: mapList(m['findings']),
    );
  }

  final String cropId;
  final String pbQuestionId;
  final String questionUid;
  final String documentId;
  final String subKey;
  final int subIndex;
  final String itemName;
  final String problemNumber;
  final String label;
  final int rawPage;
  final int? displayPage;
  final String storageBucket;
  final String storageKey;
  final String answerKind;
  final String existingAnswer;
  final bool answerManual;
  final bool hasSolutionRef;
  final int? solutionRawPage;
  final String stem;
  final String commonStem;
  final String setType;
  final String setHeaderNumber;
  final String questionType;
  final List<String> choices;
  final String? solutionTranscribed;
  final String? solutionAnswer;
  final String? aiSolution;
  final String? aiAnswer;
  final String matchMode;
  final bool? answerMatched;
  final String? mismatchReason;
  final double conceptScore;
  final double thinkingScore;
  final double arithmeticScore;
  final double totalDifficulty;
  final List<String> visualTags;
  final Map<String, dynamic> qualityChecks;
  final List<Map<String, dynamic>> draftProposals;
  final String mathStatus;
  final String qualityStatus;
  final List<Map<String, dynamic>> concepts;
  final List<Map<String, dynamic>> thinkings;
  final List<Map<String, dynamic>> arithmetics;
  final List<Map<String, dynamic>> findings;

  String get previewLookupKey => questionUid.isNotEmpty ? questionUid : pbQuestionId;

  String get displayStem {
    if (commonStem.isEmpty || stem.contains(commonStem)) return stem;
    if (stem.trim().isEmpty) return commonStem;
    return '$commonStem\n\n$stem';
  }

  bool get isSetQuestion => setType.isNotEmpty || commonStem.isNotEmpty || setHeaderNumber.isNotEmpty;
  bool get hasIssue => mathStatus == 'issue' || qualityStatus == 'issue' || findings.isNotEmpty;
  bool get hasDrafts => draftProposals.isNotEmpty;
  bool get isFullyApproved => mathStatus == 'approved' && qualityStatus == 'approved';
}

class TextbookProblemReviewService {
  TextbookProblemReviewService({
    SupabaseClient? client,
    ProblemBankService? pbService,
  })  : _db = client ?? Supabase.instance.client,
        _pb = pbService ?? ProblemBankService();

  final SupabaseClient _db;
  final ProblemBankService _pb;

  Future<List<TextbookReviewUnitScope>> fetchUnits() async {
    final res = await _db.rpc('textbook_review_books_and_units');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['units'] as List?) ?? const [])
        if (r is Map) TextbookReviewUnitScope.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<List<TextbookProblemReviewItem>> fetchUnitItems(TextbookReviewUnitScope scope) async {
    final res = await _db.rpc('textbook_review_unit_overview', params: {
      'p_academy_id': scope.academyId,
      'p_book_id': scope.bookId,
      'p_grade_label': scope.gradeLabel,
      'p_big_order': scope.bigOrder,
      'p_mid_order': scope.midOrder,
    });
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) TextbookProblemReviewItem.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// 학습앱/문제은행 카드와 동일한 서버 PDF 렌더링 엔진(V2 xelatex) 썸네일 URL을 가져온다.
  Future<Map<String, String>> fetchEnginePreviewUrls({
    required String academyId,
    required List<TextbookProblemReviewItem> items,
  }) async {
    final byDoc = <String, List<String>>{};
    final keyToCropIds = <String, List<String>>{};
    for (final it in items) {
      final k = it.previewLookupKey;
      if (k.isEmpty) continue;
      keyToCropIds.putIfAbsent(k, () => <String>[]).add(it.cropId);
      if (it.pbQuestionId.isNotEmpty && it.pbQuestionId != k) {
        keyToCropIds.putIfAbsent(it.pbQuestionId, () => <String>[]).add(it.cropId);
      }
      byDoc.putIfAbsent(it.documentId, () => <String>[]).add(k);
    }
    if (byDoc.isEmpty) return const {};

    final out = <String, String>{};
    for (final entry in byDoc.entries) {
      try {
        Map<String, String> urls = {};
        if (_pb.hasGateway) {
          try {
            urls = await _pb.batchRenderThumbnails(
              academyId: academyId,
              questionIds: entry.value,
              documentId: entry.key,
              templateProfile: 'naesin',
              paperSize: 'A4',
            );
          } catch (_) {
            urls = await _pb.fetchQuestionPreviews(
              academyId: academyId,
              questionIds: entry.value,
            );
          }
        }
        for (final u in urls.entries) {
          final crops = keyToCropIds[u.key.trim()] ?? const <String>[];
          for (final cid in crops) {
            out[cid] = u.value;
          }
        }
      } catch (_) {
        // 게이트웨이 미연결 환경에서는 빈 맵
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> runReviewChunk(
    TextbookReviewUnitScope scope, {
    int chunkSize = 8,
    bool forceRerun = false,
  }) async {
    final res = await _db.functions.invoke('ai_think', body: {
      'action': 'textbook_problem_review',
      'academy_id': scope.academyId,
      'book_id': scope.bookId,
      'grade_label': scope.gradeLabel,
      'big_order': scope.bigOrder,
      'mid_order': midOrderOf(scope),
      'chunk_size': chunkSize,
      'force_rerun': forceRerun,
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('문항 검수 응답을 해석하지 못했습니다.');
  }

  int midOrderOf(TextbookReviewUnitScope s) => s.midOrder;

  Future<int> approveAxis(List<String> cropIds, String axis) async {
    if (cropIds.isEmpty) return 0;
    final res = await _db.rpc('textbook_review_approve_axis', params: {
      'p_crop_ids': cropIds,
      'p_axis': axis,
    });
    return (res is Map ? (res['approved'] as num?)?.toInt() : null) ?? 0;
  }

  Future<void> saveItemEdit({
    required String cropId,
    String? newAnswer,
    String? aiSolution,
    required List<String> visualTags,
    bool approveMath = false,
    bool approveQuality = false,
  }) async {
    await _db.rpc('textbook_review_save_item_edit', params: {
      'p_crop_id': cropId,
      'p_new_answer': newAnswer,
      'p_ai_solution': aiSolution,
      'p_visual_tags': visualTags,
      'p_approve_math': approveMath,
      'p_approve_quality': approveQuality,
    });
  }

  Future<int> acceptDraftProposal({
    required String cropId,
    required String proposalCode,
    bool backfillMidunit = true,
  }) async {
    final res = await _db.rpc('textbook_review_accept_draft_proposal', params: {
      'p_crop_id': cropId,
      'p_proposal_code': proposalCode,
      'p_backfill_midunit': backfillMidunit,
    });
    return (res is Map ? (res['backfilled_count'] as num?)?.toInt() : null) ?? 0;
  }
}
