import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'problem_bank_service.dart';
import 'textbook_review_solution_image_service.dart';

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
    this.qualityHeldCount = 0,
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
        qualityHeldCount: (m['quality_held_count'] as num?)?.toInt() ?? 0,
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

  /// 렌더 엔진 문제로 보류된 문항 수. 품질 진행률 분모에서 빼고 따로 관리한다.
  final int qualityHeldCount;

  /// 품질 검수 분모: 엔진 보류를 뺀 문항 수(승인한 것은 완료로 집계).
  int get qualityTargetCount => (problemCount - qualityHeldCount).clamp(0, problemCount);

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
    required this.solutionSourceKind,
    required this.solutionRegion1k,
    required this.stem,
    required this.commonStem,
    required this.setType,
    required this.setHeaderNumber,
    required this.questionType,
    required this.choices,
    required this.solutionTranscribed,
    required this.solutionAnswer,
    required this.solutionSource,
    required this.alternativeSolutions,
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
    required this.renderChecks,
    required this.renderCheckedAt,
    required this.draftProposals,
    required this.mathStatus,
    required this.qualityStatus,
    required this.concepts,
    required this.thinkings,
    required this.arithmetics,
    required this.findings,
    this.rawChoices = const [],
    this.pbObjectiveAnswerKey = '',
    this.pbSubjectiveAnswer = '',
    this.pbAllowObjective = false,
    this.pbAllowSubjective = false,
    this.fixProposal = const {},
    this.engineHoldNote,
    this.engineHeldAt,
    this.engineResolvedAt,
    this.engineHoldSnapshot = const {},
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
      solutionSourceKind: '${m['solution_source_kind'] ?? 'sol'}'.trim(),
      solutionRegion1k: [
        for (final x in (m['solution_region_1k'] as List?) ?? const [])
          if (x is num) x.toInt(),
      ],
      stem: '${m['stem'] ?? ''}',
      commonStem: '${m['common_stem'] ?? ''}'.trim(),
      setType: '${m['set_type'] ?? ''}'.trim(),
      setHeaderNumber: '${m['set_header_number'] ?? ''}'.trim(),
      questionType: '${m['question_type'] ?? ''}',
      choices: [
        for (final x in (m['choices'] as List?) ?? const [])
          x is Map ? '${x['label'] ?? ''} ${x['text'] ?? ''}'.trim() : '$x',
      ],
      rawChoices: mapList(m['choices']),
      pbObjectiveAnswerKey: '${m['pb_objective_answer_key'] ?? ''}'.trim(),
      pbSubjectiveAnswer: '${m['pb_subjective_answer'] ?? ''}'.trim(),
      pbAllowObjective: m['pb_allow_objective'] == true,
      pbAllowSubjective: m['pb_allow_subjective'] == true,
      fixProposal: m['fix_proposal'] is Map ? Map<String, dynamic>.from(m['fix_proposal'] as Map) : const <String, dynamic>{},
      engineHoldNote: m['engine_hold_note'] is String ? '${m['engine_hold_note']}' : null,
      engineHeldAt: m['engine_held_at'] is String ? DateTime.tryParse('${m['engine_held_at']}') : null,
      engineResolvedAt: m['engine_resolved_at'] is String ? DateTime.tryParse('${m['engine_resolved_at']}') : null,
      engineHoldSnapshot:
          m['engine_hold_snapshot'] is Map ? Map<String, dynamic>.from(m['engine_hold_snapshot'] as Map) : const <String, dynamic>{},
      solutionTranscribed: m['solution_transcribed'] is String ? '${m['solution_transcribed']}' : null,
      solutionAnswer: m['solution_answer'] is String ? '${m['solution_answer']}' : null,
      solutionSource: m['solution_source'] is String ? '${m['solution_source']}' : null,
      alternativeSolutions: mapList(m['alternative_solutions']),
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
      renderChecks: m['render_checks'] is Map
          ? Map<String, dynamic>.from(m['render_checks'] as Map)
          : const <String, dynamic>{},
      renderCheckedAt: m['render_checked_at'] is String ? DateTime.tryParse('${m['render_checked_at']}') : null,
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

  /// 'sol' 해설 PDF · 'body' 본문 PDF · 'none' 출판사 미제공
  final String solutionSourceKind;

  /// [ymin, xmin, ymax, xmax] 0..1000 — 해설 PDF 쪽 안의 풀이 영역(content 우선, 없으면 번호 영역)
  final List<int> solutionRegion1k;
  final String stem;
  final String commonStem;
  final String setType;
  final String setHeaderNumber;
  final String questionType;
  final List<String> choices;
  final String? solutionTranscribed;
  final String? solutionAnswer;

  /// 'textbook_vision' 해설 PDF 좌표 영역을 Vision이 전사 · 'manual' 운영자 입력 · null 없음
  final String? solutionSource;

  /// 추후 확장용 대안 풀이. [{id, source, title, solution, answer, created_at}]
  final List<Map<String, dynamic>> alternativeSolutions;
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

  /// V2 렌더 학생 시점 검수 결과 {problem_ok, answer_ok, solution_ok, issue_title, issue_detail, solution_kind}
  final Map<String, dynamic> renderChecks;
  final DateTime? renderCheckedAt;
  final List<Map<String, dynamic>> draftProposals;
  final String mathStatus;
  final String qualityStatus;
  final List<Map<String, dynamic>> concepts;
  final List<Map<String, dynamic>> thinkings;
  final List<Map<String, dynamic>> arithmetics;
  final List<Map<String, dynamic>> findings;

  /// 문제은행 선지 원형 [{label, text}]. 수정 적용 때 그대로 보낸다.
  final List<Map<String, dynamic>> rawChoices;

  /// 문제은행 사본의 정답(적재 확인이 채점 정답과 대조하는 값)
  final String pbObjectiveAnswerKey;
  final String pbSubjectiveAnswer;
  final bool pbAllowObjective;
  final bool pbAllowSubjective;

  /// AI 데이터 수정 제안 {kind, stem, choices, reason, source, created_at, applied_at?, applied_fields?}
  final Map<String, dynamic> fixProposal;

  /// 렌더 엔진 보류(quality_status == 'held') 정보
  final String? engineHoldNote;
  final DateTime? engineHeldAt;
  final DateTime? engineResolvedAt;
  final Map<String, dynamic> engineHoldSnapshot;

  String get previewLookupKey => questionUid.isNotEmpty ? questionUid : pbQuestionId;

  bool get isEngineHeld => qualityStatus == 'held';

  /// 2단계(문항 카드)·4단계(정답·해설 카드) 판정에서 AI 가 분류한 원인. engine > figure > data 순으로 강한 쪽을 쓴다.
  String get issueKind {
    final a = '${qualityChecks['issue_kind'] ?? ''}';
    final b = '${renderChecks['issue_kind'] ?? ''}';
    if (a == 'engine' || b == 'engine') return 'engine';
    if (a == 'figure' || b == 'figure') return 'figure';
    if (a == 'data' || b == 'data') return 'data';
    return 'none';
  }

  bool get aiSuspectsEngine => qualityStatus == 'issue' && issueKind == 'engine';
  String get engineSymptom => '${renderChecks['engine_symptom'] ?? ''}'.trim();

  /// 아직 적용하지 않은 데이터 수정 제안이 있는가
  bool get hasPendingFixProposal {
    if (fixProposal['applied_at'] != null) return false;
    final s = fixProposal['stem'];
    final c = fixProposal['choices'];
    return (s is String && s.trim().isNotEmpty) || (c is List && c.isNotEmpty);
  }

  String? get proposedStem => fixProposal['stem'] is String && '${fixProposal['stem']}'.trim().isNotEmpty ? '${fixProposal['stem']}' : null;
  List<Map<String, dynamic>>? get proposedChoices => fixProposal['choices'] is List
      ? [for (final x in fixProposal['choices'] as List) if (x is Map) Map<String, dynamic>.from(x)]
      : null;

  /// 문제은행 사본 정답이 채점 정답과 다른가(표기 공백·$ 제거 후 단순 비교)
  bool get pbAnswerDiffers {
    String norm(String s) => s.replaceAll(RegExp(r'[\s$]'), '').toLowerCase();
    final mine = norm(existingAnswer);
    if (mine.isEmpty) return false;
    final pb = pbAllowObjective && pbObjectiveAnswerKey.isNotEmpty ? pbObjectiveAnswerKey : pbSubjectiveAnswer;
    if (pb.trim().isEmpty) return false;
    return norm(pb) != mine;
  }

  /// V2 렌더 카드 중 하나라도 이상으로 판정됐는가
  bool get renderHasIssue =>
      renderChecks['problem_ok'] == false || renderChecks['answer_ok'] == false || renderChecks['solution_ok'] == false;

  String get displayStem {
    if (commonStem.isEmpty || stem.contains(commonStem)) return stem;
    if (stem.trim().isEmpty) return commonStem;
    return '$commonStem\n\n$stem';
  }

  bool get isSetQuestion => setType.isNotEmpty || commonStem.isNotEmpty || setHeaderNumber.isNotEmpty;
  bool get hasIssue => mathStatus == 'issue' || qualityStatus == 'issue' || findings.isNotEmpty;
  bool get hasDrafts => draftProposals.isNotEmpty;
  bool get isFullyApproved => mathStatus == 'approved' && qualityStatus == 'approved';

  bool get hasOriginalSolution => (solutionTranscribed ?? '').trim().isNotEmpty;
  bool get hasAiSolution => (aiSolution ?? '').trim().isNotEmpty;

  /// 해설 좌표가 있어서 해설 PDF에서 영역을 잘라낼 수 있는 문항
  bool get canCropSolution =>
      hasSolutionRef && solutionSourceKind != 'none' && (solutionRawPage ?? 0) > 0 && solutionRegion1k.length == 4;

  /// 서버(ai_think.isReviewTodo)와 같은 기준: 미검수 · 풀이 없음 · 해설 좌표가 있는데 원본 해설 전사를 아직 시도하지 않은 문항(승인 제외).
  /// Vision 전사를 시도했다가 못 읽은 문항은 다시 대상이 되지 않는다(운영자가 좌표를 고치거나 직접 입력).
  bool get isReviewTodo {
    if (mathStatus == 'pending' || !hasAiSolution) return true;
    if (mathStatus == 'approved') return false;
    final visionTried = qualityChecks['solution_vision'] != null;
    return hasSolutionRef && !hasOriginalSolution && !visionTried;
  }

  /// 해설·정답 카드가 바뀌었거나 아직 V2 렌더 검수를 안 한 문항
  bool get needsRenderCheck => renderCheckedAt == null && (hasAiSolution || hasOriginalSolution);

  /// 학생에게 보여줄 해설 본문: 원본 해설이 있으면 원본, 없으면 AI 풀이
  String get primarySolutionText => hasOriginalSolution ? solutionTranscribed!.trim() : (aiSolution ?? '').trim();
  String get primarySolutionKind => hasOriginalSolution ? 'textbook' : 'ai';

  /// 가장 신뢰할 정답 표기: 운영자 저장 정답 → 해설 정답 → AI 정답
  String get displayAnswer {
    if (existingAnswer.trim().isNotEmpty) return existingAnswer.trim();
    if ((solutionAnswer ?? '').trim().isNotEmpty) return solutionAnswer!.trim();
    return (aiAnswer ?? '').trim();
  }
}

/// 묶음 검수 때 문항마다 함께 보내는 이미지(해설 크롭 base64 · V2 문항 카드 URL)
class TextbookReviewChunkImage {
  const TextbookReviewChunkImage({this.solutionImageBase64, this.v2ProblemUrl});

  final String? solutionImageBase64;
  final String? v2ProblemUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (solutionImageBase64 != null && solutionImageBase64!.isNotEmpty) ...{
          'solution_image_base64': solutionImageBase64,
          'solution_image_mime': 'image/png',
        },
        if (v2ProblemUrl != null && v2ProblemUrl!.isNotEmpty) 'v2_problem_url': v2ProblemUrl,
      };

  bool get isEmpty => (solutionImageBase64 ?? '').isEmpty && (v2ProblemUrl ?? '').isEmpty;
}

/// 엔진 보류 문항이 있는 단원 한 줄(textbook_review_engine_hold_list)
class TextbookReviewEngineHoldUnit {
  const TextbookReviewEngineHoldUnit({
    required this.scope,
    required this.heldCropIds,
    required this.resolvedCropIds,
  });

  factory TextbookReviewEngineHoldUnit.fromJson(Map<String, dynamic> m) => TextbookReviewEngineHoldUnit(
        scope: TextbookReviewUnitScope(
          academyId: '${m['academy_id'] ?? ''}',
          bookId: '${m['book_id'] ?? ''}',
          bookName: '${m['book_name'] ?? ''}',
          gradeLabel: '${m['grade_label'] ?? ''}',
          bigOrder: (m['big_order'] as num?)?.toInt() ?? 1,
          midOrder: (m['mid_order'] as num?)?.toInt() ?? 1,
          bigName: '${m['big_name'] ?? ''}',
          midName: '${m['mid_name'] ?? ''}',
          problemCount: 0,
          analyzedCount: 0,
          mathCleanCount: 0,
          mathIssueCount: 0,
          mathApprovedCount: 0,
          qualityCleanCount: 0,
          qualityIssueCount: 0,
          qualityApprovedCount: 0,
          qualityHeldCount: (m['held_count'] as num?)?.toInt() ?? 0,
        ),
        heldCropIds: [for (final x in (m['held_crop_ids'] as List?) ?? const []) '$x'],
        resolvedCropIds: [for (final x in (m['resolved_crop_ids'] as List?) ?? const []) '$x'],
      );

  final TextbookReviewUnitScope scope;
  final List<String> heldCropIds;
  final List<String> resolvedCropIds;
}

class TextbookReviewEngineHoldEntry {
  const TextbookReviewEngineHoldEntry({required this.unit, required this.item, required this.resolved});

  final TextbookReviewEngineHoldUnit unit;
  final TextbookProblemReviewItem item;

  /// 보류했다가 승인(해결)된 문항
  final bool resolved;

  TextbookReviewUnitScope get scope => unit.scope;
}

class TextbookProblemReviewService {
  TextbookProblemReviewService({
    SupabaseClient? client,
    ProblemBankService? pbService,
    TextbookReviewSolutionImageService? solutionImageService,
  })  : _db = client ?? Supabase.instance.client,
        _pb = pbService ?? ProblemBankService(),
        _solutionImages = solutionImageService ?? TextbookReviewSolutionImageService();

  final SupabaseClient _db;
  final ProblemBankService _pb;
  final TextbookReviewSolutionImageService _solutionImages;

  bool get hasGateway => _pb.hasGateway;

  void dispose() => _solutionImages.dispose();

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

  /// 묶음 검수 전에 문항마다 (1) 해설 PDF 좌표 영역 크롭(원본 해설 Vision 전사용) (2) V2 문항 카드 URL(학생 시점 품질 검수용)을 모은다.
  Future<Map<String, TextbookReviewChunkImage>> prepareChunkImages({
    required TextbookReviewUnitScope scope,
    required List<TextbookProblemReviewItem> items,
    required Map<String, String> previewUrlsByCropId,
  }) async {
    final out = <String, TextbookReviewChunkImage>{};
    for (final it in items) {
      String? b64;
      if (it.canCropSolution) {
        try {
          final png = await _solutionImages.renderSolutionCrop(
            academyId: scope.academyId,
            bookId: scope.bookId,
            gradeLabel: scope.gradeLabel,
            sourceKind: it.solutionSourceKind,
            rawPage: it.solutionRawPage!,
            region1k: it.solutionRegion1k,
          );
          if (png != null && png.isNotEmpty) b64 = base64Encode(png);
        } catch (_) {
          b64 = null;
        }
      }
      final v2 = previewUrlsByCropId[it.cropId];
      final img = TextbookReviewChunkImage(
        solutionImageBase64: b64,
        v2ProblemUrl: v2 != null && v2.startsWith('https://') ? v2 : null,
      );
      if (!img.isEmpty) out[it.cropId] = img;
    }
    return out;
  }

  Future<Map<String, dynamic>> runReviewChunk(
    TextbookReviewUnitScope scope, {
    int chunkSize = 6,
    bool forceRerun = false,
    List<String> cropIds = const [],
    Map<String, TextbookReviewChunkImage> images = const {},
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
      if (cropIds.isNotEmpty) 'crop_ids': cropIds,
      if (images.isNotEmpty) 'images': {for (final e in images.entries) e.key: e.value.toJson()},
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('문항 검수 응답을 해석하지 못했습니다.');
  }

  int midOrderOf(TextbookReviewUnitScope s) => s.midOrder;

  // ── V2 카드(정답·해설) 렌더 ─────────────────────────────────────────────

  /// 정답 + 해설을 한 장의 V2 카드로 찍는다(학생이 보게 될 해설 카드 그대로). URL은 서명 URL.
  Future<String> renderAnswerSolutionCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String solutionText,
    required String solutionKind,
    String? answerText,
  }) async {
    final ans = (answerText ?? item.displayAnswer).trim();
    final sol = solutionText.trim();
    if (sol.isEmpty && ans.isEmpty) return '';
    final buf = StringBuffer();
    if (ans.isNotEmpty) buf.write('정답  $ans');
    if (sol.isNotEmpty) {
      if (buf.isNotEmpty) buf.write('[문단]');
      buf.write(solutionKind == 'ai' ? '[AI 풀이]' : '[해설]');
      buf.write('[문단]');
      buf.write(sol);
    }
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-$solutionKind',
      stem: buf.toString(),
      questionNumber: item.problemNumber,
    );
  }

  /// 해설 본문만 V2 카드로 찍는다(AI 풀이·대안 풀이 카드).
  Future<String> renderSolutionOnlyCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String solutionText,
    required String kindKey,
  }) async {
    final sol = solutionText.trim();
    if (sol.isEmpty) return '';
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-$kindKey',
      stem: sol,
      questionNumber: item.problemNumber,
    );
  }

  /// 수정 제안(또는 운영자가 고친 본문·선지)을 적용하기 전에 V2 로 미리 찍어 본다.
  /// 세트 공통 지시문은 같이 붙여 학생이 볼 모양에 가깝게 한다.
  Future<String> renderProposedProblemCard({
    required String academyId,
    required TextbookProblemReviewItem item,
    required String stem,
    List<Map<String, dynamic>>? choices,
  }) async {
    final body = stem.trim();
    if (body.isEmpty) return '';
    final full = item.commonStem.isNotEmpty && !body.contains(item.commonStem) ? '${item.commonStem}[문단]$body' : body;
    return _pb.renderCustomStemThumbnail(
      academyId: academyId,
      id: 'review-${item.cropId}-fix',
      stem: full,
      questionNumber: item.problemNumber,
      choices: choices ?? item.rawChoices,
    );
  }

  /// 학생 시점 V2 렌더 검수. 문항 카드 URL과 정답+해설 카드 URL을 ai_think 에 보내 판정받는다.
  Future<Map<String, dynamic>> runRenderCheck({
    required String academyId,
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) return const {'ok': true, 'processed': 0};
    final res = await _db.functions.invoke('ai_think', body: {
      'action': 'textbook_problem_render_check',
      'academy_id': academyId,
      'items': items,
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('V2 렌더 검수 응답을 해석하지 못했습니다.');
  }

  Future<int> approveAxis(List<String> cropIds, String axis) async {
    if (cropIds.isEmpty) return 0;
    final res = await _db.rpc('textbook_review_approve_axis', params: {
      'p_crop_ids': cropIds,
      'p_axis': axis,
    });
    return (res is Map ? (res['approved'] as num?)?.toInt() : null) ?? 0;
  }

  /// 정답·풀이·해설 저장(+승인). 정답을 넘기면 문제은행 사본의 주관식·객관식 정답도 함께 맞춘다.
  /// 반환: pb_answer_sync {synced, pb_question_id, changed:[...]} (정답을 안 넘겼으면 null)
  Future<Map<String, dynamic>?> saveItemEdit({
    required String cropId,
    String? newAnswer,
    String? aiSolution,
    required List<String> visualTags,
    bool approveMath = false,
    bool approveQuality = false,
    String? solutionTranscribed,
    String? solutionAnswer,
    List<Map<String, dynamic>>? alternativeSolutions,
    bool syncPbAnswer = true,
  }) async {
    final res = await _db.rpc('textbook_review_save_item_edit', params: {
      'p_crop_id': cropId,
      'p_new_answer': newAnswer,
      'p_ai_solution': aiSolution,
      'p_visual_tags': visualTags,
      'p_approve_math': approveMath,
      'p_approve_quality': approveQuality,
      'p_solution_transcribed': solutionTranscribed,
      'p_solution_answer': solutionAnswer,
      'p_alternative_solutions': alternativeSolutions,
      'p_sync_pb_answer': syncPbAnswer,
    });
    final sync = res is Map ? res['pb_answer_sync'] : null;
    return sync is Map ? Map<String, dynamic>.from(sync) : null;
  }

  /// 본문·선지 수정을 문제은행 문항에 적용한다(+품질 승인). 반환: {changed:[stem|choices], pb_question_id, approved}
  Future<Map<String, dynamic>> applyProblemFix({
    required String cropId,
    String? stem,
    List<Map<String, dynamic>>? choices,
    bool approveQuality = false,
    String? note,
  }) async {
    final res = await _db.rpc('textbook_review_apply_problem_fix', params: {
      'p_crop_id': cropId,
      'p_stem': stem,
      'p_choices': choices,
      'p_approve_quality': approveQuality,
      'p_note': note,
    });
    return res is Map ? Map<String, dynamic>.from(res) : const {};
  }

  /// 렌더 엔진 문제로 보류(hold=true) / 보류 해제(hold=false, 다시 '오류' 상태로)
  Future<int> setEngineHold(List<String> cropIds, {required bool hold, String? note}) async {
    if (cropIds.isEmpty) return 0;
    final res = await _db.rpc('textbook_review_set_engine_hold', params: {
      'p_crop_ids': cropIds,
      'p_hold': hold,
      'p_note': note,
    });
    return (res is Map ? (res['updated'] as num?)?.toInt() : null) ?? 0;
  }

  /// 엔진 보류 문항이 있는 단원 목록(보류 중 + 최근 30일 내 해결). 문항 상세는 fetchUnitItems 로 단원별로 읽는다.
  Future<List<TextbookReviewEngineHoldUnit>> fetchEngineHoldUnits() async {
    final res = await _db.rpc('textbook_review_engine_hold_list');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['units'] as List?) ?? const [])
        if (r is Map) TextbookReviewEngineHoldUnit.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// 엔진 보류 목록의 문항 상세. 단원별 overview 를 읽어 보류·해결 crop 만 고른다.
  Future<List<TextbookReviewEngineHoldEntry>> fetchEngineHoldEntries() async {
    final units = await fetchEngineHoldUnits();
    final out = <TextbookReviewEngineHoldEntry>[];
    for (final u in units) {
      final items = await fetchUnitItems(u.scope);
      final byId = {for (final it in items) it.cropId: it};
      for (final id in u.heldCropIds) {
        final it = byId[id];
        if (it != null) out.add(TextbookReviewEngineHoldEntry(unit: u, item: it, resolved: false));
      }
      for (final id in u.resolvedCropIds) {
        final it = byId[id];
        if (it != null) out.add(TextbookReviewEngineHoldEntry(unit: u, item: it, resolved: true));
      }
    }
    return out;
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
